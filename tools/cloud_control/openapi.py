"""Live-route OpenAPI plus a narrowly scoped manual test relay."""
import re
from urllib.parse import unquote, urlsplit
from .aws import api_url
from .config import ControlError
from .health import access_token, transport


def object_schema(properties, required=None):
    return {'type': 'object', 'additionalProperties': False, 'properties': properties,
            'required': required or list(properties)}


TEXT = {'type': 'string'}
HASH = {'type': 'string', 'pattern': '^[a-f0-9]{64}$'}
LANGUAGE = {'type': 'string', 'enum': ['en', 'fr', 'es', 'de', 'it', 'pl']}
SIZE = {'type': 'integer', 'minimum': 1}
FILE = object_schema({'size_bytes': SIZE, 'sha256': HASH})


def body_schema(path):
    if path == '/v1/book-alignments':
        return object_schema({'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
            'language': LANGUAGE, 'size_bytes': {**SIZE, 'maximum': 100000000}, 'sha256': HASH})
    if path in {'/v1/alignments', '/v2/alignments'}:
        return object_schema({'language': LANGUAGE, 'profile_id': {'type': 'string', 'enum': ['base-guided-v1']},
            'allow_untimed_words': {'type': 'boolean'}, 'text': FILE,
            'audio': object_schema({'extension': {'type': 'string', 'enum': ['mp3', 'm4a', 'wav']},
                                    'size_bytes': SIZE, 'sha256': HASH})})
    if path.endswith(('/context-analyses', '/word-explanations')):
        fields = {'schema_version': {'type': 'integer', 'enum': [1]}, 'selected_text': TEXT, 'context': TEXT,
            'selection_location_utf16': {'type': 'integer', 'minimum': 0},
            'selection_length_utf16': {'type': 'integer', 'minimum': 1}, 'source_language': LANGUAGE,
            'target_language': {'type': 'string', 'enum': ['ru']}}
        fields.update({'words_to_explain': {'type': 'array', 'items': TEXT}} if path.endswith('context-analyses') else {'lemma': TEXT})
        required = list(fields)
        fields.update(model={'type': 'string', 'description': 'Необязательно: допустимая модель из настроек приложения.'},
                      reasoning_effort={'type': 'string', 'enum': ['none', 'minimal', 'low', 'medium', 'high', 'xhigh']})
        return object_schema(fields, required)
    if path.endswith('/upload-urls'):
        return object_schema({'part_numbers': {'type': 'array', 'items': {'type': 'integer', 'minimum': 1}},
                              'include_text': {'type': 'boolean'}}, ['part_numbers'])
    if path.endswith('/complete-upload'):
        return object_schema({'parts': {'type': 'array', 'items': object_schema({'part_number': SIZE, 'etag': TEXT})}})
    if path.endswith(('/start', '/complete', '/cancel', '/upload')): return object_schema({})
    return {'type': 'object', 'description': 'Контракт этого служебного маршрута уточняется в исходном OpenAPI бэкенда.'}


def specification(discovery, routes):
    endpoint = api_url(discovery['stacks'])
    paths = {}
    for route in routes:
        key = route.get('RouteKey', '')
        if ' ' not in key: continue
        method, path = key.split(' ', 1)
        if method not in {'GET', 'POST'} or not path.startswith(('/v1/', '/v2/')): continue
        parameters = [{'name': name, 'in': 'path', 'required': True, 'schema': TEXT}
                      for name in re.findall(r'\{([A-Za-z_]+)\}', path)]
        if method == 'POST' and path.endswith(('context-analyses', 'word-explanations', 'alignments')):
            parameters.append({'name': 'Idempotency-Key', 'in': 'header', 'required': True,
                               'schema': {'type': 'string', 'format': 'uuid'}})
        if method == 'GET' and path == '/v1/book-alignments':
            parameters.append({'name': 'cursor', 'in': 'query', 'schema': TEXT})
        tag = 'Книжный alignment' if 'book-alignments' in path else 'Alignment' if 'alignments' in path else 'Переводы' if any(x in path for x in ['analyses', 'explanations', 'requests']) else 'Профиль и библиотека'
        operation = {'operationId': re.sub('[^A-Za-z0-9_]', '_', method + path), 'tags': [tag],
            'summary': method + ' ' + path, 'parameters': parameters,
            'security': [{'Bearer': []}] if route.get('AuthorizationType') == 'JWT' else [],
            'responses': {str(status): {'description': title, 'content': {'application/json': {'schema': {'type': 'object'}}}}
                          for status, title in [(200, 'Результат'), (202, 'Принято'), (400, 'Некорректный запрос'),
                              (401, 'Нужен вход'), (403, 'Нет доступа'), (404, 'Не найдено'), (409, 'Конфликт состояния'), (500, 'Ошибка API')]}}
        if method == 'POST':
            operation['requestBody'] = {'required': True, 'content': {'application/json': {'schema': body_schema(path)}}}
            if path.endswith(('/context-analyses', '/word-explanations')):
                operation['requestBody']['content']['application/json']['example'] = {
                    'schema_version': 1, 'selected_text': 'dom', 'context': 'To jest dom.',
                    'selection_location_utf16': 8, 'selection_length_utf16': 3,
                    'source_language': 'pl', 'target_language': 'ru',
                    **({'words_to_explain': ['dom']} if path.endswith('/context-analyses') else {'lemma': 'dom'})}
            operation['description'] = 'Реальный запрос к выбранному AWS API. Переводы расходуют квоту провайдера; start ставит alignment в очередь. Автоматических повторов нет.'
        paths.setdefault(path, {})[method.lower()] = operation
    return {'openapi': '3.0.3', 'info': {'title': 'FLL · развёрнутый API', 'version': '1',
                'description': 'Endpoint AWS: ' + endpoint + '. Показаны только обнаруженные в API Gateway маршруты. Try it out использует локальный relay; токен из Authorize или настроенного файла access token.'},
            'servers': [{'url': endpoint, 'description': 'AWS API; Try it out проходит через локальный relay'}], 'paths': paths,
            'components': {'securitySchemes': {'Bearer': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT'}}}}


def manual(config, discovery, routes, value, call=transport):
    if set(value) - {'method', 'path', 'body', 'authorization', 'idempotency_key', 'use_saved_token'}:
        raise ControlError('Неизвестные поля ручного запроса.')
    method, path = value.get('method'), value.get('path')
    if method not in {'GET', 'POST'} or not isinstance(path, str) or len(path) > 4096:
        raise ControlError('Нужен GET или POST к маршруту выбранного API.')
    parsed = urlsplit(path)
    decoded = unquote(parsed.path)
    if (parsed.scheme or parsed.netloc or parsed.fragment or not path.startswith('/') or path.startswith('//')
            or '\\' in decoded or any(c in decoded for c in ['\r', '\n', '\x00'])
            or any(part in {'.', '..'} for part in decoded.split('/'))):
        raise ControlError('Недопустимый путь API.')
    allowed = False
    for route in routes:
        key = route.get('RouteKey', '')
        if not key.startswith(method + ' '): continue
        template = key.split(' ', 1)[1]
        if not template.startswith(('/v1/', '/v2/')): continue
        expression = re.sub(r'\\\{[A-Za-z_]+\\\}', r'[^/]+', re.escape(template))
        if re.fullmatch(expression, decoded): allowed = True; break
    if not allowed: raise ControlError('Маршрут не найден в развёрнутом API. Обновите Swagger.')
    authorization = value.get('authorization')
    if authorization is not None and not isinstance(authorization, str): raise ControlError('Некорректный bearer token.')
    if type(value.get('use_saved_token', True)) is not bool: raise ControlError('Некорректный выбор авторизации.')
    token = (access_token(config) if value.get('use_saved_token', True) else None) if not authorization else authorization.removeprefix('Bearer ')
    if token and (not isinstance(token, str) or len(token) > 16384 or any(c.isspace() for c in token)):
        raise ControlError('Некорректный bearer token.')
    key = value.get('idempotency_key')
    if key and (not isinstance(key, str) or len(key) > 100 or any(c.isspace() for c in key)):
        raise ControlError('Некорректный Idempotency-Key.')
    if value.get('body') is not None and not isinstance(value['body'], (dict, list)):
        raise ControlError('Тело ручного запроса должно быть JSON.')
    # No retries or redirects. Base URL comes only from the verified project's stack outputs.
    status, body, _ = call(api_url(discovery['stacks']), path, method, value.get('body'), token, key)
    return status, body
