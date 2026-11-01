import json
import re
import subprocess
from .config import ControlError, REPOSITORY

TAG = re.compile(r'backend-([1-9]\d*)-([a-f0-9]{12})\Z')


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
                 'refs/tags/backend-*:refs/tags/backend-*')
        return self.list()

    def list(self):
        result = []
        for line in self.git('for-each-ref', '--sort=-creatordate',
                             '--format=%(refname:short)|%(objecttype)|%(*objectname)|%(creatordate:iso8601)',
                             'refs/tags/backend-*').splitlines():
            name, kind, sha, date = line.split('|', 3)
            match = TAG.fullmatch(name)
            if match and kind == 'tag' and sha.startswith(match[2]):
                result.append({'tag': name, 'sha': sha, 'created_at': date})
        return result[:100]

    def verify(self, tag):
        match = TAG.fullmatch(tag) if isinstance(tag, str) else None
        if not match:
            raise ControlError('Выберите CI-тег вида backend-123-012345abcdef.')
        self.refresh()
        if self.git('cat-file', '-t', 'refs/tags/' + tag) != 'tag':
            raise ControlError('Нужен аннотированный CI-тег.')
        sha = self.git('rev-parse', 'refs/tags/' + tag + '^{commit}')
        if not sha.startswith(match[2]):
            raise ControlError('Тег не соответствует своему коммиту.')
        self.git('merge-base', '--is-ancestor', sha, 'origin/main')
        runs = json.loads(command(['gh', 'api',
            f'repos/{REPOSITORY}/actions/workflows/ci.yml/runs?head_sha={sha}&event=push&per_page=100']))
        approved = [r for r in runs.get('workflow_runs', []) if r.get('run_number') == int(match[1])
                    and r.get('head_sha') == sha and r.get('head_branch') == 'main'
                    and r.get('event') == 'push' and r.get('conclusion') == 'success']
        if not approved:
            raise ControlError('Для этого тега не найден успешный push-CI основной ветки. Дождитесь окончания CI.')
        return {'tag': tag, 'sha': sha, 'ci_url': approved[0]['html_url']}
