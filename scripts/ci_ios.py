#!/usr/bin/env python3
"""Build XCTest products once, then run an exhaustive frozen test shard without rebuilding."""
import argparse
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
UNIT_TARGET = 'ForeignLanguageLearnerTests'
UI_TARGET = 'ForeignLanguageLearnerUITests'
UI_SHARDS = 4


def command(argv, *, capture=False):
    print('+ ' + ' '.join(map(str, argv)), flush=True)
    result = subprocess.run(list(map(str, argv)), cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def make_plan(enumeration, revision, xcode_version):
    if enumeration.get('errors') or not enumeration.get('values'):
        raise ValueError('Xcode could not enumerate the complete test suite')
    identifiers = []
    for configuration in enumeration['values']:
        if configuration.get('disabledTests'):
            raise ValueError('Disabled tests must not disappear from required CI coverage')
        for test in configuration['enabledTests']:
            identifier = test['identifier'].removesuffix('()')
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*/[A-Za-z_][A-Za-z_0-9]*/test[A-Za-z_0-9]*', identifier):
                raise ValueError('Unsupported XCTest identifier: ' + identifier)
            identifiers.append(identifier)
    if len(identifiers) != len(set(identifiers)):
        raise ValueError('Duplicate test identifiers/configurations require explicit handling')
    if {t.split('/')[0] for t in identifiers} != {UNIT_TARGET, UI_TARGET}:
        raise ValueError('Expected nonempty unit/UI targets; update CI for new targets')
    ui = sorted(t for t in identifiers if t.startswith(UI_TARGET + '/'))
    if len(ui) < UI_SHARDS:
        raise ValueError('Not enough UI tests for nonempty shards')
    shards = {'unit': sorted(t for t in identifiers if t.startswith(UNIT_TARGET + '/'))}
    # Round-robin by method spreads the expensive library/reader classes across machines.
    shards.update({f'ui-{n+1}': ui[n::UI_SHARDS] for n in range(UI_SHARDS)})
    assigned = [t for tests in shards.values() for t in tests]
    if len(assigned) != len(identifiers) or set(assigned) != set(identifiers):
        raise ValueError('CI plan must cover every discovered test exactly once')
    return {'schema_version': 1, 'revision': revision, 'xcode_version': xcode_version,
            'architecture': platform.machine(), 'shards': shards}


def xctestrun(products):
    files = list(products.glob('*.xctestrun'))
    if len(files) != 1:
        raise ValueError('Expected one .xctestrun; use a clean build directory after changing Xcode')
    return files[0]


def simulator():
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], capture=True))['devices']
    requested = os.environ.get('SIMULATOR_ID')
    for runtime in sorted(devices, reverse=True):
        if 'iOS' not in runtime: continue
        for device in devices[runtime]:
            if (requested and device['udid'] == requested) or (not requested and device['name'].startswith('iPhone')):
                return device['udid']
    raise ValueError('No matching available iPhone simulator')


def build(derived):
    command(['bash', 'scripts/bootstrap.sh'])
    products = derived / 'Build/Products'
    for previous in products.glob('*.xctestrun'): previous.unlink()
    command(['xcodebuild', 'build-for-testing', '-project', 'ForeignLanguageLearner.xcodeproj',
             '-scheme', 'ForeignLanguageLearner', '-destination', 'generic/platform=iOS Simulator',
             '-derivedDataPath', derived, 'ARCHS=' + platform.machine(), 'ONLY_ACTIVE_ARCH=YES',
             'CODE_SIGNING_ALLOWED=NO'])
    run_file = xctestrun(products)
    enumeration = ROOT / 'build/test-enumeration.json'
    command(['xcodebuild', 'test-without-building', '-xctestrun', run_file,
             '-destination', 'platform=iOS Simulator,id=' + simulator(), '-parallel-testing-enabled', 'NO',
             '-enumerate-tests', '-test-enumeration-style', 'flat', '-test-enumeration-format', 'json',
             '-test-enumeration-output-path', enumeration])
    plan = make_plan(json.loads(enumeration.read_text()), command(['git', 'rev-parse', 'HEAD'], capture=True),
                     command(['xcodebuild', '-version'], capture=True))
    plan_file = ROOT / 'build/test-shards.json'
    plan_file.write_text(json.dumps(plan, indent=2) + '\n')
    with tarfile.open(ROOT / 'build/ios-test-products.tar.gz', 'w:gz', compresslevel=1) as archive:
        # Tar preserves executable permissions and framework symlinks through Actions artifacts.
        archive.add(products, arcname='Products')
        archive.add(plan_file, arcname='test-shards.json')
    matrix = {'include': [{'shard': name} for name in plan['shards']]}
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('matrix=' + json.dumps(matrix, separators=(',', ':')) + '\n')
    print('Test plan:', {name: len(tests) for name, tests in plan['shards'].items()}, flush=True)


def validate_shard(plan, shard, revision, xcode_version):
    if (plan.get('schema_version') != 1 or plan['revision'] != revision or plan['xcode_version'] != xcode_version
            or plan.get('architecture') != platform.machine()):
        raise ValueError('Test products belong to a different commit or Xcode build')
    tests = plan['shards'].get(shard)
    if not tests or len(tests) != len(set(tests)):
        raise ValueError('Unknown, empty or duplicate test shard')
    return tests


def run_shard(bundle, shard):
    plan = json.loads((bundle / 'test-shards.json').read_text())
    tests = validate_shard(plan, shard, command(['git', 'rev-parse', 'HEAD'], capture=True),
                           command(['xcodebuild', '-version'], capture=True))
    run_file = xctestrun(bundle / 'Products')
    results = ROOT / f'build/Tests-{shard}.xcresult'
    argv = ['xcodebuild', 'test-without-building', '-xctestrun', str(run_file),
        '-destination', 'platform=iOS Simulator,id=' + simulator(), '-resultBundlePath', str(results),
        '-parallel-testing-enabled', 'NO', '-enableCodeCoverage', 'YES', '-test-timeouts-enabled', 'YES',
        '-default-test-execution-time-allowance', '180', '-maximum-test-execution-time-allowance', '240',
        *['-only-testing:' + test for test in tests], 'CODE_SIGNING_ALLOWED=NO']
    print(f'Running {shard}: {len(tests)} frozen test identifiers', flush=True)
    result = subprocess.run(argv, cwd=ROOT)
    if results.exists():
        summary = command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', results,
                           '--compact'], capture=True)
        (ROOT / f'build/summary-{shard}.json').write_text(summary + '\n')
        count = json.loads(summary)['totalTestCount']
        if count != len(tests):
            raise ValueError(f'Incomplete shard: expected {len(tests)} tests, got {count}; inspect xcresult')
    elif result.returncode == 0:
        raise ValueError('No test results were produced')
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, ['xcodebuild', 'test-without-building'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'run'])
    parser.add_argument('--derived-data', type=Path, default=ROOT / 'build/DerivedData')
    parser.add_argument('--bundle', type=Path, default=ROOT / 'build/ci-testing')
    parser.add_argument('--shard')
    args = parser.parse_args()
    (ROOT / 'build').mkdir(exist_ok=True)
    try:
        if args.action == 'build': build(args.derived_data.resolve())
        else: run_shard(args.bundle.resolve(), args.shard)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print('CI test error:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
