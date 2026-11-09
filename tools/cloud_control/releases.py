import json
import re
import subprocess
from .config import ControlError, REPOSITORY

CORE_VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
TAG = re.compile(r'v(' + CORE_VERSION + r')-backend\.([1-9][0-9]*)\Z')
LEGACY_TAG = re.compile(r'backend-([1-9][0-9]*)-([a-f0-9]{12})\Z')
CI_URL = re.compile(r'https://github\.com/' + re.escape(REPOSITORY) + r'/actions/runs/[1-9][0-9]*\Z')


def parse_tag(name):
    if not isinstance(name, str): return None
    current = TAG.fullmatch(name)
    if current: return {'version': current[1], 'run_number': int(current[2]), 'legacy': False}
    legacy = LEGACY_TAG.fullmatch(name)
    if legacy: return {'sha_prefix': legacy[2], 'run_number': int(legacy[1]), 'legacy': True}
    return None


def command(argv, *, cwd=None, env=None, timeout=90):
    try:
        result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise ControlError('Не удалось запустить ' + argv[0] + '. Проверьте установку и доступ к сети.') from None
    if result.returncode:
        # Raw CLI errors may include credential material. Do not return them to the browser.
        raise ControlError(f'{argv[0]} завершился с ошибкой. Проверьте вход в GitHub/AWS и настройки.')
    return result.stdout


class Releases:
    def __init__(self, root):
        self.root = root

    def git(self, *args):
        return command(['git', *args], cwd=self.root).strip()

    def refresh(self):
        remote = self.git('remote', 'get-url', 'origin')
        if remote not in {f'git@github.com:{REPOSITORY}.git', f'https://github.com/{REPOSITORY}.git',
                          f'https://github.com/{REPOSITORY}'}:
            raise ControlError('origin должен указывать на ' + REPOSITORY)
        # Existing release tags cannot be silently moved by a fetch.
        self.git('fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main',
                 'refs/tags/backend-*:refs/tags/backend-*',
                 'refs/tags/v*:refs/tags/v*')
        return self.list()

    def identity(self, tag, sha):
        parsed = parse_tag(tag)
        if not parsed:
            raise ControlError('Выберите версию вида v0.0.1-backend.123.')
        if parsed['legacy']:
            if not sha.startswith(parsed['sha_prefix']):
                raise ControlError('Тег не соответствует своему коммиту.')
            return parsed
        try:
            metadata = json.loads(self.git('for-each-ref', '--format=%(contents)', 'refs/tags/' + tag))
        except (ValueError, TypeError):
            raise ControlError('Версия не содержит проверенные метаданные CI.') from None
        if (not isinstance(metadata, dict) or set(metadata) != {'schema_version', 'version', 'commit', 'ci_run_number', 'ci_url'}
                or type(metadata['schema_version']) is not int or metadata['schema_version'] != 1
                or metadata['version'] != parsed['version'] or metadata['commit'] != sha
                or type(metadata['ci_run_number']) is not int or metadata['ci_run_number'] != parsed['run_number']
                or not isinstance(metadata['ci_url'], str) or not CI_URL.fullmatch(metadata['ci_url'])):
            raise ControlError('Метаданные версии не соответствуют тегу и коммиту.')
        if self.git('show', sha + ':backend/VERSION') != parsed['version']:
            raise ControlError('Версия тега не совпадает с backend/VERSION проверенного коммита.')
        return {**parsed, 'ci_url': metadata['ci_url']}

    def list(self):
        result = []
        for line in self.git('for-each-ref', '--sort=-creatordate',
                             '--format=%(refname:short)|%(objecttype)|%(*objectname)|%(creatordate:iso8601)',
                             'refs/tags/backend-*', 'refs/tags/v*-backend.*').splitlines():
            name, kind, sha, date = line.split('|', 3)
            if kind != 'tag' or not parse_tag(name): continue
            try: parsed = self.identity(name, sha)
            except ControlError: continue
            result.append({'tag': name, 'sha': sha, 'created_at': date,
                'version': parsed.get('version'), 'legacy': parsed['legacy'],
                'operator_supported': bool(self.git('ls-tree', '--name-only', sha, 'infra/alignment/bin/operator.ts'))})
        return result[:100]

    def verify(self, tag):
        if not parse_tag(tag):
            raise ControlError('Выберите версию вида v0.0.1-backend.123.')
        self.refresh()
        if self.git('cat-file', '-t', 'refs/tags/' + tag) != 'tag':
            raise ControlError('Нужен аннотированный CI-тег.')
        sha = self.git('rev-parse', 'refs/tags/' + tag + '^{commit}')
        parsed = self.identity(tag, sha)
        self.git('merge-base', '--is-ancestor', sha, 'origin/main')
        runs = json.loads(command(['gh', 'api',
            f'repos/{REPOSITORY}/actions/workflows/ci.yml/runs?head_sha={sha}&event=push&per_page=100']))
        approved = [r for r in runs.get('workflow_runs', []) if r.get('run_number') == parsed['run_number']
                    and r.get('head_sha') == sha and r.get('head_branch') == 'main'
                    and r.get('event') == 'push' and r.get('conclusion') == 'success'
                    and (parsed['legacy'] or r.get('html_url') == parsed['ci_url'])]
        if not approved:
            raise ControlError('Для этого тега не найден успешный push-CI основной ветки. Дождитесь окончания CI.')
        return {'tag': tag, 'sha': sha, 'ci_url': approved[0]['html_url']}
