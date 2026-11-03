#!/usr/bin/env python3
"""Select UI coverage from the actual PR diff, without suppressing other CI checks."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS_PREFIXES = (
    'App/', 'Tests/UI/', '.swiftpm/',
    'ForeignLanguageLearner.xcodeproj/', 'ForeignLanguageLearner.xcworkspace/',
)
IOS_FILES = {'project.yml', 'Package.swift', 'Package.resolved', 'scripts/bootstrap.sh'}


def affects_ios(path):
    return path in IOS_FILES or path.startswith(IOS_PREFIXES)


def changed_paths(base, head, *, repo=ROOT):
    if not all(isinstance(sha, str) and re.fullmatch(r'[0-9a-fA-F]{40}', sha) for sha in [base, head]):
        raise ValueError('Expected full base/head commit SHAs from the PR event')
    # Merge-base diff excludes unrelated changes made on main after the PR branched.
    # Disable rename detection so BOTH the removed and added paths participate.
    raw = subprocess.check_output(
        ['git', 'diff', '--name-only', '-z', '--no-renames', base + '...' + head, '--'], cwd=repo)
    return [os.fsdecode(path) for path in raw.split(b'\0') if path]


def select_ui(event_name, event, *, repo=ROOT):
    if event_name != 'pull_request':
        return False
    pr = event['pull_request']
    if pr['base']['ref'] != 'main':
        return False
    return any(affects_ios(path) for path in changed_paths(pr['base']['sha'], pr['head']['sha'], repo=repo))


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        run_ui = select_ui(os.environ['GITHUB_EVENT_NAME'], event)
        value = str(run_ui).lower()
        print('UI coverage selected: ' + value)
        if output := os.environ.get('GITHUB_OUTPUT'):
            with open(output, 'a') as file:
                file.write('run_ui=' + value + '\n')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('Cannot determine UI coverage: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
