import copy
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid
from pathlib import Path
from . import health
from .aws import AWS, clean_error, deployable
from .config import ControlError, atomic_json, deployment_context, digest, expected_stacks
from .releases import Releases


def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()


def tree_digest(root):
    h = hashlib.sha256()
    for p in sorted(Path(root).rglob('*')):
        if p.is_symlink():
            if not p.resolve().is_relative_to(root): raise ControlError('Артефакт ссылается за пределы плана.')
            content = os.readlink(p).encode()
        elif p.is_file():
            content = hashlib.sha256(p.read_bytes()).digest()
        else: continue
        h.update(str(p.relative_to(root)).encode() + b'\0' + content + b'\0')
    return h.hexdigest()


class Jobs:
    def __init__(self, root, configuration, *, aws_factory=AWS, releases=None):
        self.root, self.configuration = Path(root), configuration
        self.directory = configuration.directory / 'operations'
        self.directory.mkdir(mode=0o700, exist_ok=True)
        self.plans = configuration.directory / 'plans'
        self.plans.mkdir(mode=0o700, exist_ok=True)
        self.aws_factory, self.releases = aws_factory, releases or Releases(root)
        self.lock, self.data_lock = threading.Lock(), threading.RLock()
        self.active = None
        for path in self.directory.glob('*.json'):
            value = json.loads(path.read_text())
            if value['state'] in {'queued', 'running'}:
                value.update(state='interrupted', error='Панель была остановлена. Проверьте реальное состояние AWS; автоповтора нет.', ended_at=now())
                atomic_json(path, value)

    def list(self):
        with self.data_lock:
            return sorted([json.loads(p.read_text()) for p in self.directory.glob('*.json')],
                          key=lambda v: v['created_at'], reverse=True)[:60]

    def get(self, key):
        if not re.fullmatch('[a-f0-9]{32}', key): raise ControlError('Операция не найдена.')
        path = self.directory / (key + '.json')
        if not path.exists(): raise ControlError('Операция не найдена.')
        with self.data_lock: return json.loads(path.read_text())

    def update(self, key, **fields):
        with self.data_lock:
            value = self.get(key); value.update(fields)
            atomic_json(self.directory / (key + '.json'), value)
        return value

    def log(self, key, text):
        # Never persist raw tokens even if a subprocess unexpectedly prints one.
        text = re.sub(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[JWT REDACTED]', text)
        text = re.sub(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b', '[AWS KEY REDACTED]', text)
        with self.data_lock:
            value = self.get(key)
            self.update(key, log=(value.get('log', '') + text + '\n')[-180000:])

    def execute(self, key, argv, *, cwd, env=None, timeout=1200, require_full_output=False):
        self.log(key, '→ ' + Path(argv[0]).name + ' ' + (' '.join(argv[1:3])))
        timed_out = False
        # An unlinked temporary file cannot retain unredacted subprocess output after a crash.
        with tempfile.TemporaryFile() as stream:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            self.update(key, child_pid=process.pid)
            try: status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
                timed_out = True
            finally: self.update(key, child_pid=None)
            size = os.fstat(stream.fileno()).st_size
            if size > 150000:
                self.log(key, 'Журнал команды превышает лимит; показана последняя часть.')
            stream.seek(max(0, size - 150000))
            self.log(key, stream.read().decode(errors='replace'))
        if timed_out: raise ControlError('Превышено время операции. Проверьте состояние AWS; автоповтора нет.')
        if size > 150000 and require_full_output:
            raise ControlError('Изменений слишком много для просмотра в панели. План не разрешён к деплою; используйте ручную проверку.')
        if status: raise ControlError('Команда завершилась с ошибкой; подробности в журнале операции.')

    def start(self, action, body):
        if not self.lock.acquire(blocking=False):
            raise ControlError('Уже выполняется операция. Дождитесь её завершения.')
        key = uuid.uuid4().hex
        try:
            for operation in self.list():
                pid = operation.get('child_pid')
                if not pid: continue
                try: os.kill(pid, 0)
                except ProcessLookupError: continue
                except PermissionError: pass
                raise ControlError('Дочерний процесс предыдущей операции ещё работает. Проверьте журнал и AWS; новый запуск заблокирован.')
            if action not in {'refresh', 'prepare', 'deploy', 'tests'}: raise ControlError('Неизвестная операция.')
            config = self.configuration.load() if action != 'refresh' else None
            if action == 'deploy':
                plan = self.get(body.get('plan_id', ''))
                self.validate_plan(plan, config, body)
            if action == 'tests' and body.get('mode', 'smoke') == 'inference' and body.get('confirm') != '2':
                raise ControlError('Подтвердите до двух платных тестовых запросов вводом числа 2.')
            atomic_json(self.directory / (key + '.json'), {'id': key, 'action': action, 'state': 'queued',
                'created_at': now(), 'account_id': config['account_id'] if config else None,
                'region': config['region'] if config else None,
                'tag': body.get('tag', plan.get('tag') if action == 'deploy' else None), 'log': ''})
            self.active = key
            thread = threading.Thread(target=self.perform, args=(key, action, copy.deepcopy(body), config), daemon=True)
            thread.start()
            return self.get(key)
        except Exception:
            self.lock.release(); raise

    def validate_plan(self, plan, config, body):
        if plan.get('action') != 'prepare' or plan.get('state') != 'ready':
            raise ControlError('Сначала подготовьте новый план.')
        if body.get('confirm') != f"{config['account_id']}/{plan['tag']}":
            raise ControlError('Подтверждение должно совпадать с номером аккаунта и выбранным тегом.')
        if time.time() - plan['prepared_at'] > 3600:
            raise ControlError('План старше часа. Подготовьте его заново.')
        if plan['config_hash'] != digest(config): raise ControlError('Настройки изменились. Подготовьте план заново.')
        if tree_digest(self.plans / plan['id']) != plan['artifact_hash']:
            raise ControlError('Файлы подготовленной версии изменились. Подготовьте план заново.')

    def environment(self, config):
        env = dict(os.environ)
        # A named SSO/profile is the authority; ambient static/session credentials must not override it.
        for name in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_SECURITY_TOKEN',
                     'AWS_WEB_IDENTITY_TOKEN_FILE', 'AWS_ROLE_ARN', 'AWS_ROLE_SESSION_NAME']:
            env.pop(name, None)
        env.update(AWS_PROFILE=config['profile'], AWS_REGION=config['region'], AWS_DEFAULT_REGION=config['region'],
                   CDK_DEFAULT_ACCOUNT=config['account_id'], CDK_DEFAULT_REGION=config['region'], CI='true', NO_COLOR='1')
        return env

    def perform(self, key, action, body, config):
        try:
            self.update(key, state='running', started_at=now())
            if action == 'refresh':
                tags = self.releases.refresh()
                self.update(key, tags=tags, state='passed')
            elif action == 'prepare': self.prepare(key, config, body)
            elif action == 'deploy': self.deploy(key, config, body)
            else:
                aws = self.aws_factory(config)
                report = health.run(config, aws.snapshot(), body.get('mode', 'smoke'),
                    checkpoint=lambda r: self.update(key, report=r))
                self.update(key, state=report['state'])
        except Exception as error:
            detail = str(error) if isinstance(error, ControlError) else 'Операция недоступна: ' + clean_error(error)
            self.update(key, state='failed', error=detail)
        finally:
            self.update(key, ended_at=now()); self.active = None; self.lock.release()

    def prepare(self, key, config, body):
        context = deployment_context(config)
        release = self.releases.verify(body.get('tag'))
        self.update(key, **release)
        aws = self.aws_factory(config)
        snapshot = aws.snapshot(); deployable(snapshot)
        if any(s['status'] != 'NOT_DEPLOYED' and s['name'] not in expected_stacks(config) for s in snapshot):
            raise ControlError('Конфигурация исключает уже развёрнутый стек. Верните его в состав релиза; панель не удаляет стеки.')
        area = self.plans / key
        area.mkdir(mode=0o700)
        source = area / 'source'; source.mkdir()
        archive = area / 'source.tar'
        self.execute(key, ['git', 'archive', '--format=tar', '--output', str(archive), release['sha']], cwd=self.root)
        with tarfile.open(archive) as bundle: bundle.extractall(source, filter='data')
        archive.unlink()
        for required in ['scripts/build-cloud.py', 'infra/alignment/bin/cloud.ts']:
            if not (source / required).exists(): raise ControlError('Этот тег не содержит поддерживаемый облачный бэкенд.')
        roots = area / 'roots'; roots.mkdir()
        for p in Path(config['apple_roots']).glob('*.cer'): shutil.copyfile(p, roots / p.name)
        policy = area / 'policy.json'; shutil.copyfile(config['policy_file'], policy)
        context.update(stage='prod', cloudAsset=str(area / 'lambda'), cloudPolicy=str(policy))
        if context.get('paidAlignment') == 'true':
            if not config.get('alignment_benchmark_file'): raise ControlError('Нужен подтверждённый benchmark report для платного аудио.')
            benchmark = area / 'benchmark.json'; shutil.copyfile(config['alignment_benchmark_file'], benchmark)
            context['alignmentBenchmarkReport'] = str(benchmark)
        env = self.environment(config)
        self.execute(key, [sys.executable, str(source / 'scripts/build-cloud.py'), '--apple-roots', str(roots),
            '--output', str(area / 'lambda'), *[arg for h in config['root_sha256'] for arg in ['--root-sha256', h]]],
            cwd=source, env=env)
        infra = source / 'infra/alignment'
        self.execute(key, ['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], cwd=infra, env=env)
        cdk = str(infra / 'node_modules/.bin/cdk')
        # Fixed app command, never a command supplied by the browser or the tag field.
        self.execute(key, [cdk, '--app', 'node_modules/.bin/ts-node bin/cloud.ts', 'synth', '--all',
            '--lookups=false', '--output', str(area / 'assembly'),
            *[arg for k, v in sorted(context.items()) for arg in ['--context', f'{k}={v}']]], cwd=infra, env=env)
        manifest = json.loads((area / 'assembly/manifest.json').read_text())
        stacks = [a for a in manifest['artifacts'].values() if a['type'] == 'aws:cloudformation:stack']
        if sorted(a['properties']['stackName'] for a in stacks) != sorted(expected_stacks(config)) or any(
                a['environment'] != f"aws://{config['account_id']}/{config['region']}" for a in stacks):
            raise ControlError('Состав или окружение стеков не совпадает с ожидаемым prod.')
        for artifact in stacks:
            template = json.loads((area / 'assembly' / artifact['properties']['templateFile']).read_text())
            if any(r['Type'] == 'AWS::ApiGatewayV2::Route' and r['Properties'].get('AuthorizationType') != 'JWT'
                   and not r['Properties'].get('RouteKey', '').startswith('POST /v1/webhooks/')
                   for r in template['Resources'].values()):
                raise ControlError('План содержит незащищённый API-маршрут.')
        self.execute(key, [cdk, '--app', str(area / 'assembly'), 'diff', '--all', '--no-change-set',
                          '--profile', config['profile']], cwd=infra, env=env, require_full_output=True)
        self.update(key, state='ready', prepared_at=time.time(), artifact_hash=tree_digest(area),
            config_hash=digest(config), baseline=snapshot, context=context,
            account_id=config['account_id'], region=config['region'])

    def deploy(self, key, config, body):
        plan = self.get(body['plan_id'])
        self.validate_plan(plan, config, body)
        # Recheck the remote CI tag; no local tag/manifest can authorize another revision.
        verified = self.releases.verify(plan['tag'])
        if verified['sha'] != plan['sha']: raise ControlError('Ревизия тега изменилась.')
        aws = self.aws_factory(config)
        current = aws.snapshot(); deployable(current)
        if digest(current) != digest(plan['baseline']):
            raise ControlError('Prod изменился после подготовки. Подготовьте новый план.')
        area = self.plans / plan['id']
        infra = area / 'source/infra/alignment'
        self.update(plan['id'], state='consumed')
        self.update(key, tag=plan['tag'], sha=plan['sha'], plan_id=plan['id'], before=current)
        self.execute(key, [str(infra / 'node_modules/.bin/cdk'), '--app', str(area / 'assembly'),
            'deploy', '--all', '--profile', config['profile'], '--require-approval', 'never', '--rollback',
            '--outputs-file', str(self.directory / (key + '.outputs.json')),
            '--tags', f"ControlReleaseTag={plan['tag']}", '--tags', f"ControlRevision={plan['sha']}",
            '--tags', f'ControlOperation={key}'], cwd=infra, env=self.environment(config), timeout=3600)
        after = aws.snapshot()
        self.update(key, deployed=True, after=after)
        report = health.run(config, after, checkpoint=lambda r: self.update(key, report=r))
        self.update(key, state='passed' if report['state'] == 'passed' else 'warning',
                    warning=None if report['state'] == 'passed' else 'Версия развёрнута, но проверки неполны или не прошли. См. отчёт.')
