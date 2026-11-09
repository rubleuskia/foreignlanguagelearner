"""Real HTTPS probes, without retries of potentially billable submissions."""
import json
import time
import uuid
from pathlib import Path
from urllib import error, request
from .aws import api_url
from .config import ControlError, is_operator


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise error.HTTPError(req.full_url, code, 'Redirect refused', headers, fp)


def transport(base, path, method='GET', body=None, token=None, key=None):
    headers = {'Content-Type': 'application/json', 'User-Agent': 'FLL-Local-Control/1'}
    if token: headers['Authorization'] = 'Bearer ' + token
    if key: headers['Idempotency-Key'] = key
    req = request.Request(base + path, method=method, headers=headers,
                          data=None if body is None else json.dumps(body).encode())
    started = time.monotonic()
    try:
        response = request.build_opener(NoRedirect()).open(req, timeout=30)
    except error.HTTPError as exc:
        response = exc
    with response:
        raw = response.read(131073)
        if len(raw) > 131072: raise ControlError('Ответ API превышает допустимый размер.')
        try: value = json.loads(raw)
        except (ValueError, UnicodeError): value = None
        return response.code, value, round((time.monotonic() - started) * 1000)


def access_token(config):
    path = config.get('access_token_file')
    if not path: return None
    path = Path(path)
    if path.stat().st_mode & 0o077:
        raise ControlError('Файл тестового access token должен быть доступен только владельцу (chmod 600).')
    token = path.read_text().strip()
    if not 20 <= len(token) <= 16384 or any(c.isspace() for c in token):
        raise ControlError('В файле ожидается один Cognito access token без префикса Bearer.')
    return token


def run(config, snapshot, mode='smoke', *, call=transport, checkpoint=lambda value: None,
        clock=time.monotonic, sleep=time.sleep):
    if mode not in {'smoke', 'inference'}: raise ControlError('Неизвестный набор тестов.')
    base = api_url(snapshot)
    token = access_token(config)
    operator = is_operator(config)
    if mode == 'inference' and not token:
        raise ControlError('Для сквозного теста нужен access token отдельного тестового подписчика.')
    report = {'mode': mode, 'endpoint': base, 'cases': [], 'requests': [], 'coverage': 'public'}

    def save(): checkpoint(report)

    def probe(name, path, expected, method='GET', body=None, auth=False, check=lambda value: True):
        try:
            code, value, latency = call(base, path, method, body, token if auth else None)
            ok = code == expected and check(value)
            row = {'name': name, 'state': 'passed' if ok else 'failed', 'http': code, 'latency_ms': latency}
        except Exception:
            value = None
            row = {'name': name, 'state': 'failed', 'detail': 'Нет корректного ответа HTTPS API.'}
        report['cases'].append(row); save()
        return row['state'] == 'passed', value

    for path, method in [('/v1/me', 'GET'), ('/v1/me/entitlements', 'GET'),
                         ('/v1/context-analyses', 'POST'), ('/v1/word-explanations', 'POST'),
                         ('/v1/requests/' + str(uuid.uuid4()), 'GET')]:
        if operator and path == '/v1/me/entitlements': continue
        probe(f'{method} {"/v1/requests/{id}" if "requests/" in path else path}: без входа',
              path, 401, method, {} if method == 'POST' else None)
    if operator and config.get('context', {}).get('operatorAlignment', 'true') == 'true':
        probe('Аудио оператора: без входа', '/v1/alignments', 401, 'POST', {})
    if config.get('context', {}).get('paidAlignment') == 'true':
        probe('Платное аудио: без входа', '/v2/alignments', 401, 'POST', {})
    probe('Неизвестный маршрут', '/control-nonexistent-' + str(uuid.uuid4()), 404)
    if not token:
        report['cases'].append({'name': 'Профиль, подписка и каталог с авторизацией', 'state': 'skipped',
            'detail': 'Не задан файл access token. Доступность авторизованных функций не проверена.'})
    else:
        report['coverage'] = 'authenticated'
        probe('Профиль тестового аккаунта', '/v1/me', 200, auth=True,
              check=lambda v: isinstance(v, dict) and v.get('schema_version') == 1 and bool(v.get('user_id')) and (v.get('role') == 'operator' if operator else bool(v.get('app_account_token'))))
        if operator:
            probe('Защищённая проверка доступности', '/v1/health', 200, auth=True,
                  check=lambda v: isinstance(v, dict) and v.get('status') == 'ok')
        else:
            probe('Подписка и остатки лимитов', '/v1/me/entitlements', 200, auth=True,
                  check=lambda v: isinstance(v, dict) and v.get('schema_version') == 1
                  and isinstance(v.get('features'), dict) and isinstance(v.get('allowance'), dict))
            probe('Каталог и доступность покупок', '/v1/products', 200, auth=True,
                  check=lambda v: isinstance(v, dict) and v.get('schema_version') == 1
                  and isinstance(v.get('products'), list) and type(v.get('purchases_enabled')) is bool)
        probe('Чужой/несуществующий ключ запроса', '/v1/requests/by-key/' + str(uuid.uuid4()), 404, auth=True)
        probe('Неверный запрос отклоняется до расхода квоты', '/v1/context-analyses', 400, 'POST', {}, auth=True)
    if mode == 'inference':
        if any(row['state'] == 'failed' for row in report['cases']):
            report['state'] = 'failed'; save()
            return report
        report['coverage'] = 'inference'
        # Checkpoint UUIDs BEFORE POST. A lost response never triggers a second POST.
        from backend.translation.contract import validate_output
        common = {'schema_version': 1, 'selected_text': 'dom', 'context': 'To jest dom.',
            'selection_location_utf16': 8, 'selection_length_utf16': 3, 'source_language': 'pl', 'target_language': 'ru'}
        for kind, path, extra in [('context', '/v1/context-analyses', {'words_to_explain': ['dom']}),
                                  ('word', '/v1/word-explanations', {'lemma': 'dom'})]:
            item = {'kind': kind, 'key': str(uuid.uuid4()), 'state': 'submitting'}
            report['requests'].append(item); save()
            payload = {**common, **extra}
            try:
                try:
                    code, value, _ = call(base, path, 'POST', payload, token, item['key'])
                    if code not in ({200, 202} if operator else {202}): raise ControlError('Admission rejected')
                except Exception:
                    # Recover by key even when the submission response was lost.
                    code, value, _ = call(base, '/v1/requests/by-key/' + item['key'], token=token)
                    if code != 200: raise ControlError('Submission outcome is unknown')
                item['request_id'] = value['request_id']; item['state'] = value['state']; save()
                deadline = clock() + 150
                while value['state'] in {'accepted', 'running'} and clock() < deadline:
                    sleep(2)
                    code, value, _ = call(base, '/v1/requests/' + item['request_id'], token=token)
                    if code != 200: raise ControlError('Polling failed')
                    item['state'] = value['state']; save()
                if value['state'] != 'succeeded': raise ControlError('No successful result')
                code, value, _ = call(base, '/v1/requests/' + item['request_id'], token=token)
                if code != 200 or value.get('request_id') != item['request_id'] or value.get('state') != 'succeeded':
                    raise ControlError('Durable result retrieval failed')
                validate_output(kind, value['result'], payload)
                # Same POST/key must recover the same success without reserving/invoking again.
                code, again, _ = call(base, path, 'POST', payload, token, item['key'])
                if (code not in ({200, 202} if operator else {202}) or again.get('request_id') != item['request_id'] or again.get('state') != 'succeeded'
                        or again.get('result') != value['result']):
                    raise ControlError('Idempotency failed')
                report['cases'].append({'name': f'{kind}: результат, схема и повтор ключа', 'state': 'passed'})
            except Exception:
                report['cases'].append({'name': f'{kind}: результат, схема и повтор ключа', 'state': 'failed',
                    'detail': 'Запрос не завершён успешно. Ключ сохранён; автоматической новой отправки не будет.'})
                if item['state'] in {'submitting', 'accepted', 'running'}: item['state'] = 'outcome_unknown'
                # Do not continue spending after a failed first inference.
                break
            save()
    report['state'] = ('failed' if any(r['state'] == 'failed' for r in report['cases']) else
                       'warning' if any(r['state'] == 'skipped' for r in report['cases']) else 'passed')
    save()
    return report
