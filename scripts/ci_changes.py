#!/usr/bin/env python3
"""Select simulator coverage from changed iOS inputs; keep device/backend checks."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS_PREFIXES = (
    'App/', 'Shared/', 'YouTubeShare/', 'Tests/UI/', '.swiftpm/',
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


def select_ios_tests(event_name, event, *, repo=ROOT):
    if event_name == 'pull_request':
        pr = event['pull_request']
        base, head = pr['base']['sha'], pr['head']['sha']
    elif event_name == 'push':
        base, head = event['before'], event['after']
        if base == '0' * 40:
            return True  # Initial branch creation has no previous tree to compare.
    else:
        return True  # Explicit manual/reusable runs retain full unit coverage.
    paths = changed_paths(base, head, repo=repo)
    return any(affects_ios(path) or path.startswith('Tests/Unit/')
               or path == 'scripts/ci_ios.py' for path in paths)


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        event_name = os.environ['GITHUB_EVENT_NAME']
        run_ui = select_ui(event_name, event)
        run_ios_tests = select_ios_tests(event_name, event)
        value = str(run_ui).lower()
        print('UI coverage selected: ' + value)
        print('iOS simulator tests selected: ' + str(run_ios_tests).lower())
        if output := os.environ.get('GITHUB_OUTPUT'):
            with open(output, 'a') as file:
                file.write('run_ui=' + value + '\n')
                file.write('run_ios_tests=' + str(run_ios_tests).lower() + '\n')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('Cannot determine UI coverage: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
