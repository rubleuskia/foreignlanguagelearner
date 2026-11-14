"""Explain the selected release and the actual prepared CloudFormation resource diff."""
import json
from pathlib import Path
import re
import time
from .config import ControlError, deployment_context, digest, expected_stacks, is_operator
from .monitoring import resources, stamp


def template_changes(before, after, stack):
    old, new = before.get('Resources', {}), after.get('Resources', {})
    result = []
    for key in sorted(old.keys() | new.keys()):
        left, right = old.get(key), new.get(key)
        if left is not None and right is not None and digest(left) == digest(right):
            continue
        action = 'add' if left is None else 'remove' if right is None else 'modify'
        changed = []
        if action == 'modify':
            a, b = left.get('Properties', {}), right.get('Properties', {})
            changed = [name for name in sorted(a.keys() | b.keys()) if a.get(name) != b.get(name)]
            changed += [name for name in sorted(left.keys() | right.keys())
                        if name != 'Properties' and left.get(name) != right.get(name)]
        result.append({'stack': stack, 'logical_id': key, 'type': (right or left)['Type'],
                       'action': action, 'changed_fields': changed,
                       'retained': action == 'remove' and left.get('DeletionPolicy') in {'Retain', 'RetainExceptOnCreate'},
                       'review': action == 'remove' or (right or left)['Type'].startswith('AWS::IAM::')})
    for section in ['Outputs', 'Parameters', 'Conditions', 'Mappings']:
        left, right = before.get(section, {}), after.get(section, {})
        for key in sorted(left.keys() | right.keys()):
            if key not in left or key not in right or left[key] != right[key]:
                result.append({'stack': stack, 'logical_id': section + '.' + key, 'type': 'CloudFormation::' + section,
                    'action': 'add' if key not in left else 'remove' if key not in right else 'modify',
                    'changed_fields': [section], 'review': key not in right})
    return result


def prepared_changes(aws, area, artifacts, baseline):
    result = []
    assembly = (Path(area) / 'assembly').resolve()
    for name, artifact in artifacts.items():
        stack = artifact['properties'].get('stackName') or name
        path = (assembly / artifact['properties']['templateFile']).resolve()
        if not path.is_relative_to(assembly): raise ControlError('Шаблон находится за пределами плана.')
        after = json.loads(path.read_text())
        previous = next((row for row in baseline if row['name'] == stack), None)
        before = {}
        if previous and previous['status'] != 'NOT_DEPLOYED':
            before = aws.client('cloudformation').get_template(StackName=stack, TemplateStage='Original')['TemplateBody']
            if isinstance(before, str): before = json.loads(before)
            if not isinstance(before, dict): raise ControlError('Не удалось прочитать развёрнутый шаблон ' + stack)
        result += template_changes(before, after, stack)
    return result


def summary(releases, config, discovery, operations, tag=None, *, now=None, candidates=None):
    now = time.time() if now is None else now
    candidates = [r for r in (releases.list() if candidates is None else candidates) if not is_operator(config) or r.get('operator_supported')]
    selected = next((r for r in candidates if r['tag'] == tag), None) if tag else next(iter(candidates), None)
    if tag and not selected: raise ControlError('Выберите CI-тег из списка доступных версий.')
    stacks = [s for s in discovery['stacks'] if s['name'] in expected_stacks(config)]
    deployed = [{'name': s['name'], 'status': s['status'], 'tag': s['tags'].get('ControlReleaseTag'),
                 'sha': s['tags'].get('ControlRevision')} for s in stacks]
    notes, changes = [], []
    try: deployment_context(config)
    except ControlError as error: notes.append(str(error))
    has_books = False
    if selected:
        sha = selected['sha']
        if not re.fullmatch('[a-f0-9]{40}', sha): raise ControlError('Некорректная ревизия версии.')
        has_books = bool(releases.git('ls-tree', '--name-only', sha, 'backend/book_alignment/api.py'))
        for row in deployed:
            current = row.get('sha')
            files = None
            if current and re.fullmatch('[a-f0-9]{40}', current):
                try: files = releases.git('diff', '--name-only', current, sha, '--', 'backend', 'infra', 'scripts/build-cloud.py').splitlines()
                except ControlError: pass
            changes.append({'stack': row['name'], 'current_tag': row['tag'], 'target_tag': selected['tag'],
                            'same_revision': current == sha, 'changed_files': files})
        if not has_books and is_operator(config):
            notes.append('В выбранном теге ещё нет очередного книжного alignment. Для этой фичи нужен CI-тег после её слияния в main.')
    else:
        notes.append('Нет совместимого CI-тега. Получите теги после успешного CI основной ветки.')
    deployed_books = {
        'API книжного alignment': any(r['logical_id'].startswith('Books') for r in resources(discovery, 'AWS::ApiGatewayV2::Route')),
        'Хранилище S3 для книг': any('BooksArtifacts' in r['logical_id'] or r['logical_id'] == 'BookAlignmentBucket' for r in resources(discovery, 'AWS::S3::Bucket')),
        'Запросы и история DynamoDB': any('BooksRequests' in r['logical_id'] for r in resources(discovery, 'AWS::DynamoDB::Table')),
        'Очередь SQS': any('BooksQueue' in r['logical_id'] for r in resources(discovery, 'AWS::SQS::Queue')),
        'Сервис книжного worker ECS': any('BooksWorkers' in r['logical_id'] for r in resources(discovery, 'AWS::ECS::Service')),
    }
    if has_books and not all(deployed_books.values()):
        notes.append('Нужен новый immutable-образ с книжным consumer. Тег кода сам не пересобирает образ в ECR: проверьте digest и замеры, затем подготовьте план обоих операторских стеков.')
    plan = next((p for p in operations if p.get('action') == 'prepare' and p.get('state') == 'ready'
                 and p.get('account_id') == config['account_id'] and p.get('tag') == (selected or {}).get('tag')), None)
    invalid = []
    if plan:
        if now - plan.get('prepared_at', 0) > 3600: invalid.append('План старше часа; подготовьте его заново.')
        if plan.get('region') != config['region']: invalid.append('Регион плана не совпадает с настройками.')
        if plan.get('config_hash') != digest(config): invalid.append('Настройки изменились после подготовки.')
        baseline = {s['name']: digest(s) for s in plan.get('baseline', []) if s['name'] in expected_stacks(config)}
        if baseline != {s['name']: digest(s) for s in stacks}: invalid.append('Состояние AWS изменилось после подготовки.')
    return {'selected': selected, 'deployed': deployed, 'comparisons': changes,
            'book_components': [{'name': key, 'deployed': value, 'in_selected_release': has_books} for key, value in deployed_books.items()],
            'notes': notes, 'plan': {'id': plan['id'], 'prepared_at': plan.get('prepared_at'),
                'valid': not invalid, 'invalid_reasons': invalid, 'expires_at': plan.get('prepared_at', 0) + 3600,
                'resource_changes': plan.get('resource_changes'), 'tag': plan['tag']} if plan else None,
            'checked_at': stamp(), 'note': 'Кандидат выбирается из локального списка CI-тегов. При подготовке снова проверяются main и успешный CI. Точные изменения ресурсов доступны только после подготовки плана.'}
