"""Read-only project telemetry. No resource creation or implicit paid inference."""
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import json
import math
import re
from .aws import api_url, clean_error
from .config import ControlError, expected_stacks

UTC = timezone.utc
TERMINAL = {'succeeded', 'succeeded_with_review', 'failed', 'cancelled', 'expired'}


def stamp():
    return datetime.now(UTC).isoformat()


def redact(message):
    text = str(message)
    text = re.sub(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[JWT REDACTED]', text)
    text = re.sub(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b', '[AWS KEY REDACTED]', text)
    text = re.sub(r'\bsk-[A-Za-z0-9_-]{12,}', '[API KEY REDACTED]', text)
    text = re.sub(r'(?i)(Bearer\s+)[^\s"\',}]+', r'\1[REDACTED]', text)
    text = re.sub(r'(?i)([?&]X-Amz-[^=\s]+)=([^&\s"\']+)', r'\1=[REDACTED]', text)
    text = re.sub(r'(?i)("?(?:access_?token|refresh_?token|password|client_?secret|secret_?access_?key|session_?token|api_?key)"?\s*[:=]\s*")[^"]*"',
                  r'\1[REDACTED]"', text)
    return text[:16000]


def resources(discovery, kind):
    return [row for row in discovery['resources'] if row['type'] == kind]


class Monitoring:
    def __init__(self, aws, discovery=None, now=None):
        self.aws, self.discovery = aws, discovery
        self.now = now or datetime.now(UTC)

    def discover(self):
        snapshot = [s for s in self.aws.snapshot() if s['name'] in expected_stacks(self.aws.config)]
        client = self.aws.client('cloudformation')
        result, warnings = [], []
        observed = list(snapshot)
        for name in ['ForeignLanguageLearnerBookLibrary-prod', 'CDKToolkit']:
            try:
                extra = client.describe_stacks(StackName=name)['Stacks'][0]
                observed.append({'name': name, 'status': extra['StackStatus'],
                    'outputs': {item['OutputKey']: item['OutputValue'] for item in extra.get('Outputs', [])}})
            except Exception as error:
                if clean_error(error) != 'ValidationError' or 'does not exist' not in str(error):
                    warnings.append({'source': name, 'error': clean_error(error)})
        for stack in observed:
            if stack['status'] == 'NOT_DEPLOYED':
                continue
            try:
                for page in client.get_paginator('list_stack_resources').paginate(StackName=stack['name']):
                    for row in page.get('StackResourceSummaries', []):
                        if row.get('PhysicalResourceId'):
                            result.append({'stack': stack['name'], 'logical_id': row['LogicalResourceId'],
                                           'type': row['ResourceType'], 'id': row['PhysicalResourceId']})
            except Exception as error:
                warnings.append({'source': stack['name'], 'error': clean_error(error)})
            # Imported curated-library storage is an output, not a resource in the API stack.
            for name in ['BookLibraryBucket', 'BookAlignmentBucket']:
                bucket = stack.get('outputs', {}).get(name)
                if bucket and not any(r['id'] == bucket and r['type'] == 'AWS::S3::Bucket' for r in result):
                    result.append({'stack': stack['name'], 'logical_id': name, 'type': 'AWS::S3::Bucket', 'id': bucket})
        return {'stacks': snapshot, 'resources': result, 'warnings': warnings, 'checked_at': stamp()}

    def storage(self, bucket=None, cursor=None, prefix=''):
        buckets = resources(self.discovery, 'AWS::S3::Bucket')
        selected = next((b for b in buckets if b['id'] == bucket), None) if bucket else next(iter(buckets), None)
        if bucket and selected is None:
            raise ControlError('Этот bucket не относится к ресурсам проекта.')
        result = {'buckets': buckets, 'bucket': selected, 'files': [], 'cursor': None,
                  'checked_at': stamp(), 'warnings': self.discovery['warnings']}
        if not selected:
            return result
        if not isinstance(prefix, str) or len(prefix) > 1024:
            raise ControlError('Префикс S3 должен быть не длиннее 1024 символов.')
        pagination = {'MaxItems': 100, 'PageSize': 100}
        if cursor:
            if len(cursor) > 8192: raise ControlError('Некорректная страница S3.')
            pagination['StartingToken'] = cursor
        page = self.aws.client('s3').get_paginator('list_objects_v2').paginate(
            Bucket=selected['id'], Prefix=prefix, PaginationConfig=pagination).build_full_result()
        result['files'] = [{'key': item['Key'], 'bytes': item['Size'],
                            'modified_at': item['LastModified'].isoformat(),
                            'storage_class': item.get('StorageClass', 'STANDARD')} for item in page.get('Contents', [])]
        result['cursor'] = page.get('NextToken')
        result['page_bytes'] = sum(item['bytes'] for item in result['files'])
        result['scope'] = 'Текущие версии объектов; сумма относится только к этой странице. Старые версии также могут занимать место.'
        return result

    def costs(self):
        result = {'total': None, 'services': [], 'daily': [], 'currency': 'USD', 'estimated': False,
                  'start': self.now.date().replace(day=1).isoformat(),
                  'end_exclusive': (self.now.date() + timedelta(days=1)).isoformat(),
                  'checked_at': stamp(), 'warnings': [], 'plan': None,
                  'scope': 'Выбранный проект AWS. Оплата OpenAI сюда не входит.',
                  'note': 'Данные Cost Explorer поступают с задержкой. Кэш — 15 минут; это не итоговый счёт.'}
        try: result.update(self._cost_usage())
        except Exception as error: result['warnings'].append({'source': 'Cost Explorer', 'error': clean_error(error)})
        try:
            plan = self.aws.session.client('freetier', region_name='us-east-1', config=self.aws.options).get_account_plan_state()
            if plan.get('accountId') != self.aws.config['account_id']:
                raise ControlError('Сведения о плане относятся к другому проекту.')
            credit = plan.get('accountPlanRemainingCredits') or {}
            expiration = plan.get('accountPlanExpirationDate')
            result['plan'] = {'type': plan.get('accountPlanType'), 'status': plan.get('accountPlanStatus'),
                'remaining_credits': str(credit['amount']) if credit.get('amount') is not None else None,
                'currency': credit.get('unit'), 'expires_at': expiration.isoformat() if hasattr(expiration, 'isoformat') else expiration}
        except Exception as error: result['warnings'].append({'source': 'AWS plan', 'error': clean_error(error)})
        if result['warnings'] and result['total'] is None and not result['plan']:
            result.update(available=False, error='Данные расходов и плана недоступны: ' + '; '.join(w['source'] + ': ' + w['error'] for w in result['warnings']))
        return result

    def _cost_usage(self):
        # Date comes from the runtime clock, never a fixed release/build date.
        today = self.now.date()
        start = today.replace(day=1)
        end = today + timedelta(days=1)  # CE end is exclusive; today's data may still be absent.
        client = self.aws.session.client('ce', region_name='us-east-1', config=self.aws.options)
        paginator = client.get_paginator('get_cost_and_usage')
        totals, daily, units = defaultdict(Decimal), defaultdict(Decimal), set()
        estimated = False
        for page in paginator.paginate(TimePeriod={'Start': start.isoformat(), 'End': end.isoformat()},
                Granularity='DAILY', Metrics=['UnblendedCost'], GroupBy=[{'Type': 'DIMENSION', 'Key': 'SERVICE'}],
                Filter={'Dimensions': {'Key': 'LINKED_ACCOUNT', 'Values': [self.aws.config['account_id']]}}):
            for period in page.get('ResultsByTime', []):
                estimated |= period.get('Estimated', False)
                for group in period.get('Groups', []):
                    metric = group['Metrics']['UnblendedCost']
                    amount = Decimal(metric['Amount'])
                    if not amount.is_finite(): raise ControlError('Cost Explorer вернул некорректную сумму.')
                    units.add(metric['Unit'])
                    totals[group['Keys'][0]] += amount
                    daily[period['TimePeriod']['Start']] += amount
        if len(units) > 1:
            raise ControlError('Cost Explorer вернул разные валюты; суммы не объединены.')
        return {'start': start.isoformat(), 'end_exclusive': end.isoformat(), 'currency': next(iter(units), 'USD'),
                'total': str(sum(totals.values(), Decimal(0))) if totals else None,
                'services': [{'name': key, 'amount': str(value)} for key, value in sorted(totals.items(), key=lambda x: x[1], reverse=True)],
                'daily': [{'date': key, 'amount': str(value)} for key, value in sorted(daily.items())],
                'estimated': estimated, 'checked_at': stamp(), 'metric': 'UnblendedCost',
                'scope': 'Весь выбранный проект AWS, включая глобальные сервисы, кредиты и возвраты. Оплата OpenAI сюда не входит.',
                'note': 'Данные Cost Explorer поступают с задержкой и могут уточняться. Кэш — 15 минут; это не итоговый счёт.'}

    def alignment(self, days=30):
        if days not in {7, 30, 90}: raise ControlError('Период: 7, 30 или 90 дней.')
        start = int((self.now - timedelta(days=days)).timestamp())
        end = int(self.now.timestamp())
        tables = [r for r in resources(self.discovery, 'AWS::DynamoDB::Table') if 'Alignment' in r['stack']
                  and ('JobsTable' in r['logical_id'] or 'Requests' in r['logical_id'])]
        rows, sources, warnings = [], [], list(self.discovery['warnings'])
        fields = ['job_id', 'title', 'language', 'status', 'stage', 'progress', 'created_at', 'updated_at',
                  'completed_at', 'worker_claimed_at', 'attempts', 'history', 'size_bytes',
                  'expected_audio_bytes', 'expected_text_bytes', 'start_requested_at', 'error_code']
        for source in tables:
            complete = True
            try:
                native = self.aws.session.resource('dynamodb', config=self.aws.options).meta.client
                attributes = {f'#f{i}': name for i, name in enumerate(fields)}
                client = native.get_paginator('scan')
                pages = client.paginate(TableName=source['id'],
                    FilterExpression='attribute_exists(#f0) AND #f6 BETWEEN :start AND :end',
                    ProjectionExpression=', '.join(attributes), ExpressionAttributeNames=attributes,
                    ExpressionAttributeValues={':start': start, ':end': end},
                    PaginationConfig={'PageSize': 200, 'MaxItems': 10000})
                count = 0
                for index, page in enumerate(pages):
                    count += len(page.get('Items', []))
                    rows.extend(normalize_job(item, source['id'], end) for item in page.get('Items', []))
                    if (index >= 49 or count >= 10000) and page.get('LastEvaluatedKey'):
                        complete = False; break
                sources.append({'table': source['id'], 'complete': complete, 'records': count})
            except Exception as error:
                warnings.append({'source': source['id'], 'error': clean_error(error)})
        durations = [r['runtime_seconds'] for r in rows if r['status'] in TERMINAL and r['runtime_seconds'] is not None]
        durations.sort()
        statuses = Counter(r['status'] for r in rows)
        return {'days': days, 'start': start, 'end': end, 'requests': len(rows),
                'executions': sum(r['attempts'] for r in rows), 'statuses': dict(statuses),
                'input_bytes': sum(r['input_bytes'] or 0 for r in rows),
                'mean_runtime_seconds': sum(durations) / len(durations) if durations else None,
                'p95_runtime_seconds': durations[math.ceil(len(durations) * .95) - 1] if durations else None,
                'duration_samples': len(durations), 'jobs': sorted(rows, key=lambda r: r['created_at'], reverse=True)[:200],
                'sources': sources, 'warnings': warnings, 'complete': bool(tables) and not warnings and all(s['complete'] for s in sources),
                'checked_at': stamp(), 'scope': 'Задачи, созданные за выбранный период, которые ещё есть в БД. Старый пилот удаляет записи по TTL; это не число запусков за всё время.',
                'duration_note': 'Время — от первого захвата worker до завершения, включая повторы. Ожидание очереди показано отдельно. Отсутствующие метрики не заменяются нулём.'}

    def routes(self):
        rows = []
        for api in resources(self.discovery, 'AWS::ApiGatewayV2::Api'):
            for page in self.aws.client('apigatewayv2').get_paginator('get_routes').paginate(ApiId=api['id']):
                rows += [r for r in page.get('Items', []) if r.get('RouteKey') != '$default']
        return rows

    def errors(self, group=None, cursor=None, hours=24):
        if hours not in {1, 24}: raise ControlError('Период ошибок: 1 или 24 часа.')
        start = self.now - timedelta(hours=hours)
        metrics, warnings = [], list(self.discovery['warnings'])
        for api in resources(self.discovery, 'AWS::ApiGatewayV2::Api'):
            try:
                values = {}
                for metric in ['Count', '5xx']:
                    points = self.aws.client('cloudwatch').get_metric_statistics(Namespace='AWS/ApiGateway',
                        MetricName=metric, Dimensions=[{'Name': 'ApiId', 'Value': api['id']}],
                        StartTime=start, EndTime=self.now, Period=3600, Statistics=['Sum'])['Datapoints']
                    values[metric] = sum(p['Sum'] for p in points) if points else None
                metrics.append({'api_id': api['id'], 'requests': values['Count'], 'errors_5xx': values['5xx']})
            except Exception as error:
                warnings.append({'source': api['id'], 'error': clean_error(error)})
        groups = sorted(resources(self.discovery, 'AWS::Logs::LogGroup'), key=lambda r: ('AccessLogs' not in r['logical_id'], r['logical_id']))
        selected = next((g for g in groups if g['id'] == group), None) if group else next(iter(groups), None)
        if group and selected is None: raise ControlError('Эта группа логов не относится к проекту.')
        events, next_cursor = [], None
        if selected:
            params = {'logGroupName': selected['id'], 'startTime': int(start.timestamp() * 1000),
                      'endTime': int(self.now.timestamp() * 1000), 'limit': 50,
                      'filterPattern': '%5[0-9][0-9]%' if 'AccessLogs' in selected['logical_id'] else
                                       '%ERROR|Exception|Traceback|_error|_failed|_retry|timed out|Error%'}
            if cursor:
                if len(cursor) > 8192: raise ControlError('Некорректная страница логов.')
                params['nextToken'] = cursor
            try:
                page = self.aws.client('logs').filter_log_events(**params)
                next_cursor = page.get('nextToken')
                for item in page.get('events', []):
                    message = item['message']
                    if 'AccessLogs' in selected['logical_id']:
                        try:
                            if not 500 <= int(json.loads(message).get('status', 0)) <= 599: continue
                        except (ValueError, TypeError): continue
                    events.append({'timestamp': item['timestamp'], 'stream': item.get('logStreamName'),
                                   'message': redact(message), 'id': item['eventId']})
            except Exception as error:
                warnings.append({'source': selected['id'], 'error': clean_error(error)})
        return {'hours': hours, 'metrics': metrics, 'groups': groups, 'group': selected,
                'events': sorted(events, key=lambda e: e['timestamp'], reverse=True), 'cursor': next_cursor,
                'warnings': warnings, 'checked_at': stamp(),
                'scope': 'Счётчики 5xx — из CloudWatch; логи — отдельная страница выбранной группы. Пустая страница или отсутствие метрики не подтверждают отсутствие ошибок.'}


def normalize_job(row, table, now):
    history = row.get('history', [])
    started = row.get('worker_claimed_at') or next((h.get('at') for h in history if h.get('status') == 'downloading'), None)
    queued = next((h.get('at') for h in history if h.get('status') == 'queued'), None) or row.get('start_requested_at')
    status = row.get('status', 'unknown')
    ended = row.get('completed_at') or (row.get('updated_at') if status in TERMINAL else now)
    runtime = int(ended) - int(started) if started and ended and int(ended) >= int(started) else None
    size = row.get('size_bytes')
    if size is None and 'expected_audio_bytes' in row:
        size = int(row['expected_audio_bytes']) + int(row.get('expected_text_bytes', 0))
    return {'job_id': row['job_id'], 'table': table, 'title': row.get('title') or 'Alignment ' + row['job_id'][:10],
            'language': row.get('language'), 'status': status, 'stage': row.get('stage'),
            'progress': int(row['progress']) if row.get('progress') is not None else None,
            'created_at': int(row.get('created_at', 0)), 'input_bytes': int(size) if size is not None else None,
            'input_kind': 'ZIP' if 'size_bytes' in row else 'Аудио + текст',
            'attempts': int(row.get('attempts', 1 if started else 0)), 'runtime_seconds': runtime,
            'queue_seconds': max(0, int(started) - int(queued)) if started and queued else None,
            'error_code': row.get('error_code')}
