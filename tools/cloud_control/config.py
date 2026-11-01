import hashlib
import json
import os
import re
from pathlib import Path


class ControlError(Exception):
    pass


CONTEXT_KEYS = {
    'appleClientId', 'appleTeamId', 'appleSignInKeyId', 'appleSignInSecretArn',
    'appleApiSecretArn', 'openaiSecretArn', 'callbackUrl', 'loginDomainPrefix',
    'appleProducts', 'appAppleId', 'acceptTranslations', 'paidAlignment',
    'cloudComponents', 'workerRepositoryName', 'workerImageDigest',
}
REQUIRED_CONTEXT = {
    'appleClientId', 'appleTeamId', 'appleSignInKeyId', 'appleSignInSecretArn',
    'appleApiSecretArn', 'callbackUrl', 'loginDomainPrefix', 'appleProducts', 'appAppleId',
}
REPOSITORY = 'rubleuskia/foreignlanguagelearner'


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.chmod(0o600)
    temporary.replace(path)


def validate(value):
    allowed = {'account_id', 'region', 'profile', 'context', 'apple_roots', 'root_sha256',
               'policy_file', 'alignment_benchmark_file', 'access_token_file'}
    if not isinstance(value, dict) or set(value) - allowed:
        raise ControlError('Неизвестные поля настройки. Секретные ключи здесь не поддерживаются.')
    if not isinstance(value.get('account_id'), str) or not re.fullmatch(r'\d{12}', value['account_id']):
        raise ControlError('Нужен 12-значный AWS account ID, не адрес электронной почты.')
    if value.get('region') != 'eu-central-1':
        raise ControlError('Текущие облачные стеки поддерживают регион eu-central-1 (Франкфурт).')
    if not isinstance(value.get('profile'), str) or not re.fullmatch(r'[\w.@+-]{1,100}', value['profile']):
        raise ControlError('Укажите имя локального AWS-профиля.')
    context = value.get('context', {})
    if not isinstance(context, dict) or set(context) - CONTEXT_KEYS or any(
            not isinstance(v, str) or len(v) > 2048 or '\n' in v for v in context.values()):
        raise ControlError('Допускаются только перечисленные публичные параметры CDK и ARN секретов.')
    for key in ['appleSignInSecretArn', 'appleApiSecretArn', 'openaiSecretArn']:
        if key in context and not re.fullmatch(
                rf"arn:aws:secretsmanager:eu-central-1:{value['account_id']}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{{6}}", context[key]):
            raise ControlError(f'{key}: нужен полный ARN секрета в выбранном AWS-аккаунте, не его содержимое.')
    for key in ['acceptTranslations', 'paidAlignment']:
        if key in context and context[key] not in {'true', 'false'}: raise ControlError(f'{key}: ожидается true или false.')
    if context.get('cloudComponents', 'all') not in {'billing', 'all'}: raise ControlError('cloudComponents: billing или all.')
    for field in ['apple_roots', 'policy_file', 'alignment_benchmark_file', 'access_token_file']:
        if field in value and (not isinstance(value[field], str) or not Path(value[field]).is_absolute()):
            raise ControlError(f'{field}: нужен абсолютный путь на этом компьютере.')
    hashes = value.get('root_sha256', [])
    if not isinstance(hashes, list) or any(not isinstance(h, str) or not re.fullmatch('[a-fA-F0-9]{64}', h) for h in hashes):
        raise ControlError('Отпечатки сертификатов должны быть SHA-256 в hex.')
    return value


class Configuration:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / 'config.json'

    def load(self):
        if not self.path.exists():
            raise ControlError('AWS не настроен. Откройте «Настройка» и укажите аккаунт и профиль.')
        return validate(json.loads(self.path.read_text()))

    def save(self, value):
        atomic_json(self.path, validate(value))

    def public(self):
        return json.loads(self.path.read_text()) if self.path.exists() else None


def deployment_context(config):
    context = dict(config['context'])
    missing = REQUIRED_CONTEXT - context.keys()
    if context.get('cloudComponents') != 'billing' and not context.get('openaiSecretArn'):
        missing.add('openaiSecretArn')
    if missing:
        raise ControlError('Для подготовки релиза заполните параметры: ' + ', '.join(sorted(missing)))
    if not re.fullmatch(r'[1-9]\d*', context['appAppleId']):
        raise ControlError('Для prod нужен числовой appAppleId из App Store Connect.')
    if not config.get('apple_roots') or not config.get('root_sha256') or not config.get('policy_file'):
        raise ControlError('Укажите каталог Apple DER roots, проверенные SHA-256 и файл политики.')
    return context


def expected_stacks(config):
    names = ['ForeignLanguageLearnerCloudFoundation-prod', 'ForeignLanguageLearnerCloudBilling-prod']
    if config.get('context', {}).get('cloudComponents') != 'billing':
        names.append('ForeignLanguageLearnerCloudTranslation-prod')
    if config.get('context', {}).get('paidAlignment') == 'true':
        names.append('ForeignLanguageLearnerPaidAlignment-prod')
    return names


ALL_STACKS = ['ForeignLanguageLearnerCloudFoundation-prod', 'ForeignLanguageLearnerCloudBilling-prod',
              'ForeignLanguageLearnerCloudTranslation-prod', 'ForeignLanguageLearnerPaidAlignment-prod']


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
