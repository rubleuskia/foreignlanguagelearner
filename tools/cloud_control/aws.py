import datetime
import json
import threading
import time
from .config import ALL_STACKS, REGION, ControlError, digest, is_operator, expected_stacks, deployment_context


def clean_error(error):
    code = getattr(error, 'response', {}).get('Error', {}).get('Code')
    return code or type(error).__name__


class AWS:
    def __init__(self, config):
        import boto3
        from botocore.config import Config
        self.config = config
        self.session = boto3.Session(profile_name=config['profile'], region_name=config['region'])
        self.options = Config(connect_timeout=5, read_timeout=10, retries={'max_attempts': 0})

    def client(self, name):
        return self.session.client(name, config=self.options)

    def identity(self):
        actual = self.client('sts').get_caller_identity()['Account']
        if actual != self.config['account_id']:
            raise ControlError('AWS-профиль вошёл в другой аккаунт. Операция заблокирована.')
        return actual

    def snapshot(self):
        self.identity()
        cf = self.client('cloudformation')
        rows = []
        for name in ALL_STACKS:
            try:
                stack = cf.describe_stacks(StackName=name)['Stacks'][0]
            except Exception as error:
                if clean_error(error) == 'ValidationError' and 'does not exist' in str(error):
                    rows.append({'name': name, 'status': 'NOT_DEPLOYED', 'tags': {}, 'outputs': {}})
                    continue
                raise
            stamp = stack.get('LastUpdatedTime', stack['CreationTime']).isoformat()
            template = cf.get_template(StackName=name, TemplateStage='Original')['TemplateBody']
            rows.append({'name': name, 'id': stack['StackId'], 'status': stack['StackStatus'],
                'updated_at': stamp, 'template_hash': digest(template),
                'tags': {t['Key']: t['Value'] for t in stack.get('Tags', [])},
                'outputs': {t['OutputKey']: t['OutputValue'] for t in stack.get('Outputs', [])}})
        return rows

    def status(self):
        rows = self.snapshot()
        cf = self.client('cloudformation')
        names = []
        for row in rows:
            if row['status'] == 'NOT_DEPLOYED': continue
            for page in cf.get_paginator('list_stack_resources').paginate(StackName=row['name']):
                names.extend(r['PhysicalResourceId'] for r in page['StackResourceSummaries']
                    if r['ResourceType'] == 'AWS::CloudWatch::Alarm' and r.get('PhysicalResourceId'))
        alarms = []
        for offset in range(0, len(names), 100):
            result = self.client('cloudwatch').describe_alarms(AlarmNames=names[offset:offset+100])
            alarms.extend({'name': a['AlarmName'], 'state': a['StateValue']} for a in result['MetricAlarms'])
        # Infrastructure success and alarms are displayed separately from API functional coverage.
        visible = expected_stacks(self.config) if is_operator(self.config) else ALL_STACKS[:4]
        return {'configured': True, 'account_id': self.config['account_id'], 'region': self.config['region'],
            'stacks': [r for r in rows if r['name'] in visible or r['status'] != 'NOT_DEPLOYED'],
            'alarms': alarms, 'deployment_mode': self.config.get('deployment_mode', 'subscription'),
            'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}

    def require_bootstrap(self):
        try:
            self.client('cloudformation').describe_stacks(StackName='CDKToolkit')
        except Exception as error:
            message = getattr(error, 'response', {}).get('Error', {}).get('Message', '')
            if clean_error(error) == 'ValidationError' and 'does not exist' in message:
                raise ControlError('CDKToolkit отсутствует. Нужна одноразовая подготовка CDK в eu-north-1 '
                    'перед подготовкой плана публикации. Инструкция: docs/OPERATOR_CLOUD.md, '
                    '«Before preparation», шаг 3. Панель не создаёт служебные роли автоматически.') from None
            raise
        return 'CDKToolkit найден'

    def readiness(self):
        """Metadata reads only. This does not invoke Bedrock, bootstrap or publish images."""
        from pathlib import Path
        cases = []
        def record(name, fn):
            try:
                detail = fn()
                cases.append({'name': name, 'state': 'passed', 'detail': detail or 'Готово'})
            except Exception as error:
                cases.append({'name': name, 'state': 'failed', 'detail': str(error) if isinstance(error, ControlError)
                              else 'Проверка недоступна: ' + clean_error(error)})
        record('Доступ к проекту AWS', lambda: str(self.identity()))
        record('Параметры выбранного этапа', lambda: (deployment_context(self.config), 'Настройки заполнены')[1])
        record('Подготовка AWS для CDK', self.require_bootstrap)
        if is_operator(self.config):
            model = 'qwen.qwen3-235b-a22b-2507-v1:0'
            def model_access():
                value = self.client('bedrock').get_foundation_model_availability(modelId=model)
                if (value.get('authorizationStatus') != 'AUTHORIZED' or value.get('regionAvailability') != 'AVAILABLE'
                        or value.get('entitlementAvailability') != 'AVAILABLE'
                        or value.get('agreementAvailability', {}).get('status') != 'AVAILABLE'):
                    raise ControlError('Модель пока не разрешена проекту в Стокгольме.')
                return 'Разрешение найдено; платный вызов и верификация проекта проверяются отдельно.'
            record('Bedrock Qwen3: регион и разрешение', model_access)
            ctx = self.config.get('context', {})
            if ctx.get('operatorAlignment', 'true') == 'true':
                def image():
                    if not ctx.get('workerRepositoryName') or not ctx.get('workerImageDigest'):
                        raise ControlError('Образ аудио ещё не указан. Заполните репозиторий и digest в настройках.')
                    self.client('ecr').describe_images(repositoryName=ctx['workerRepositoryName'],
                                                      imageIds=[{'imageDigest': ctx['workerImageDigest']}])
                    return 'Неизменяемый образ найден в ECR'
                record('Образ обработчика аудио', image)
                def benchmark():
                    import json
                    from .config import validate_benchmark
                    path = self.config.get('alignment_benchmark_file')
                    if not path: raise ControlError('Укажите файл реальных замеров образа.')
                    validate_benchmark(json.loads(Path(path).read_text()), ctx.get('workerImageDigest'), operator=True)
                    return 'Отчёт соответствует образу и ограничениям'
                record('Замеры обработчика аудио', benchmark)
        return {'cases': cases, 'ready': all(c['state'] == 'passed' for c in cases),
                'note': 'Перед публикацией нужен совместимый проверенный CI-тег. Эта проверка не вызывает модель и не подтверждает её качество.'}


def deployable(snapshot):
    good = {'NOT_DEPLOYED', 'CREATE_COMPLETE', 'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE', 'IMPORT_COMPLETE'}
    if any(s['status'] not in good for s in snapshot):
        raise ControlError('Один из стеков занят или требует восстановления в CloudFormation. Деплой заблокирован.')


def api_url(snapshot):
    from urllib.parse import urlparse
    base = next((s['outputs'].get('ApiUrl') for s in snapshot
                 if s['name'].endswith(('Foundation-prod', 'Operator-prod'))), None)
    parsed = urlparse(base or '')
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path not in {'', '/'}
            or not parsed.hostname.endswith(f'.execute-api.{REGION}.amazonaws.com')):
        raise ControlError('В prod-стеке нет ожидаемого HTTPS API Gateway endpoint.')
    return base.rstrip('/')
