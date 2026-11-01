import datetime
import json
import threading
import time
from .config import ALL_STACKS, REGION, ControlError, digest


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
        return {'configured': True, 'account_id': self.config['account_id'], 'region': self.config['region'],
            'stacks': rows, 'alarms': alarms, 'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}


def deployable(snapshot):
    good = {'NOT_DEPLOYED', 'CREATE_COMPLETE', 'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE', 'IMPORT_COMPLETE'}
    if any(s['status'] not in good for s in snapshot):
        raise ControlError('Один из стеков занят или требует восстановления в CloudFormation. Деплой заблокирован.')


def api_url(snapshot):
    from urllib.parse import urlparse
    base = next((s['outputs'].get('ApiUrl') for s in snapshot if s['name'].endswith('Foundation-prod')), None)
    parsed = urlparse(base or '')
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path not in {'', '/'}
            or not parsed.hostname.endswith(f'.execute-api.{REGION}.amazonaws.com')):
        raise ControlError('В prod-стеке нет ожидаемого HTTPS API Gateway endpoint.')
    return base.rstrip('/')
