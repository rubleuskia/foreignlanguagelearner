#!/usr/bin/env python3
"""Build XCTest products once, then run an exhaustive frozen test shard without rebuilding."""
import argparse
from contextlib import contextmanager
import json
import os
import platform
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
UNIT_TARGET = 'ForeignLanguageLearnerTests'
UI_TARGET = 'ForeignLanguageLearnerUITests'
UI_SHARDS = 4


def command(argv, *, capture=False, timeout=None):
    print('+ ' + ' '.join(map(str, argv)), flush=True)
    result = subprocess.run(list(map(str, argv)), cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, timeout=timeout)
    return result.stdout.strip() if capture else None


def make_plan(enumeration, revision, xcode_version):
    if enumeration.get('errors') or not enumeration.get('values'):
        raise ValueError('Xcode could not enumerate the complete test suite: ' +
                         json.dumps(enumeration.get('errors', []), ensure_ascii=False))
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


def validate_compiled_targets(run_file):
    value = plistlib.loads(run_file.read_bytes())
    if 'TestConfigurations' in value:
        targets = [t for c in value['TestConfigurations'] for t in c.get('TestTargets', [])]
    else:
        targets = [t for t in value.values() if isinstance(t, dict) and 'TestBundlePath' in t]
    names = {t.get('BlueprintName') for t in targets}
    if names != {UNIT_TARGET, UI_TARGET}:
        raise ValueError('Update CI for the compiled test targets: ' + repr(names))


def simulator_template():
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], capture=True))['devices']
    requested = os.environ.get('SIMULATOR_ID')
    for runtime in sorted(devices, reverse=True):
        if 'iOS' not in runtime: continue
        for device in devices[runtime]:
            if (requested and device['udid'] == requested) or (not requested and device['name'].startswith('iPhone')):
                return runtime, device
    raise ValueError('No matching available iPhone simulator')


@contextmanager
def prepared_simulator(label):
    runtime, template = simulator_template()
    owned = not os.environ.get('SIMULATOR_ID')
    sid = template['udid']
    if owned:
        device_type = template.get('deviceTypeIdentifier')
        if not device_type:
            types = json.loads(command(['xcrun', 'simctl', 'list', 'devicetypes', '-j'], capture=True))['devicetypes']
            device_type = next(t['identifier'] for t in types if t['name'] == template['name'])
        sid = command(['xcrun', 'simctl', 'create', f'FLL CI {label}-{uuid.uuid4().hex[:8]}',
                       device_type, runtime], capture=True, timeout=60)
    try:
        if owned or template['state'] == 'Shutdown':
            command(['xcrun', 'simctl', 'boot', sid], timeout=60)
        # An available UUID is not a ready simulator. Wait for first boot before testmanagerd starts.
        # Hosted first-boot migrations exceed three minutes; restarting repeats that work.
        command(['xcrun', 'simctl', 'bootstatus', sid, '-b'], timeout=600)
        yield sid
    finally:
        if owned:
            for operation in ['shutdown', 'delete']:
                try:
                    subprocess.run(['xcrun', 'simctl', operation, sid], capture_output=True, timeout=30)
                except (OSError, subprocess.TimeoutExpired):
                    print('Could not finish temporary simulator cleanup: ' + operation, file=sys.stderr)


class DiscoveryBootstrapError(ValueError):
    pass


def target_enumeration(value, target):
    errors = value.get('errors', [])
    if errors:
        message = json.dumps(errors, ensure_ascii=False)
        if all(isinstance(error, str) and 'Lost connection to testmanagerd' in error for error in errors):
            raise DiscoveryBootstrapError(message)
        raise ValueError('Xcode enumeration failed: ' + message)
    enabled = []
    for configuration in value.get('values', []):
        # -only-testing intentionally disables the other bundle; discover that bundle separately.
        if any(t['identifier'].split('/')[0] == target for t in configuration.get('disabledTests', [])):
            raise ValueError('Selected target contains disabled tests: ' + target)
        for test in configuration.get('enabledTests', []):
            if not test['identifier'].startswith(target + '/'):
                raise ValueError('Target enumeration is incomplete or contains an unexpected bundle: ' + test['identifier'])
            enabled.append(test)
    if not enabled:
        raise ValueError('Empty target enumeration: ' + target)
    return {'errors': [], 'values': [{'enabledTests': enabled, 'disabledTests': []}]}


def discover_target(run_file, target, directory):
    for attempt in [1, 2]:
        prefix = f'{target}-{attempt}-{uuid.uuid4().hex[:8]}'
        output = directory / f'test-enumeration-{prefix}.json'
        try:
            with prepared_simulator('discover-' + target) as sid:
                failed = None
                try:
                    command(['xcodebuild', 'test-without-building', '-xctestrun', run_file,
                        '-destination', 'platform=iOS Simulator,id=' + sid, '-parallel-testing-enabled', 'NO',
                        '-only-testing:' + target, '-resultBundlePath', directory / f'Enumeration-{prefix}.xcresult',
                        '-enumerate-tests', '-test-enumeration-style', 'flat', '-test-enumeration-format', 'json',
                        '-test-enumeration-output-path', output], timeout=240)
                except subprocess.CalledProcessError as error:
                    failed = error
                except subprocess.TimeoutExpired as error:
                    raise DiscoveryBootstrapError('XCTest discovery timed out: ' + str(error)) from error
                if not output.exists():
                    if failed: raise failed
                    raise ValueError('Xcode did not write the discovery manifest for ' + target)
                result = target_enumeration(json.loads(output.read_text()), target)
                if failed: raise failed
                return result
        except DiscoveryBootstrapError as error:
            # Discovery runs no test methods. Retry only its infrastructure bootstrap on a fresh device.
            print(f'Discovery bootstrap failed for {target}, attempt {attempt}: {error}', flush=True)
            if attempt == 2: raise
    raise ValueError('No complete enumeration for ' + target)


def compile_products(derived):
    (ROOT / 'build/test-shards.json').unlink(missing_ok=True)
    command(['bash', 'scripts/bootstrap.sh'])
    products = derived / 'Build/Products'
    for previous in products.glob('*.xctestrun'): previous.unlink()
    command(['xcodebuild', 'build-for-testing', '-project', 'ForeignLanguageLearner.xcodeproj',
             '-scheme', 'ForeignLanguageLearner', '-destination', 'generic/platform=iOS Simulator',
             '-derivedDataPath', derived, 'ARCHS=' + platform.machine(), 'ONLY_ACTIVE_ARCH=YES',
             'CODE_SIGNING_ALLOWED=NO'])


def plan_tests(derived):
    (ROOT / 'build/test-shards.json').unlink(missing_ok=True)
    (ROOT / 'build/test-enumeration.json').unlink(missing_ok=True)
    run_file = xctestrun(derived / 'Build/Products')
    validate_compiled_targets(run_file)
    enumeration = {'errors': [], 'values': []}
    for target in [UI_TARGET, UNIT_TARGET]:
        enumeration['values'].extend(discover_target(run_file, target, ROOT / 'build')['values'])
    (ROOT / 'build/test-enumeration.json').write_text(json.dumps(enumeration, indent=2) + '\n')
    plan = make_plan(enumeration, command(['git', 'rev-parse', 'HEAD'], capture=True),
                     command(['xcodebuild', '-version'], capture=True))
    plan_file = ROOT / 'build/test-shards.json'
    plan_file.write_text(json.dumps(plan, indent=2) + '\n')
    matrix = {'include': [{'shard': name} for name in plan['shards']]}
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('matrix=' + json.dumps(matrix, separators=(',', ':')) + '\n')
    print('Test plan:', {name: len(tests) for name, tests in plan['shards'].items()}, flush=True)


def package_products(derived):
    plan = json.loads((ROOT / 'build/test-shards.json').read_text())
    revision = command(['git', 'rev-parse', 'HEAD'], capture=True)
    version = command(['xcodebuild', '-version'], capture=True)
    for shard in plan['shards']: validate_shard(plan, shard, revision, version)
    with tarfile.open(ROOT / 'build/ios-test-products.tar.gz', 'w:gz', compresslevel=1) as archive:
        # Tar preserves executable permissions and framework symlinks through Actions artifacts.
        archive.add(derived / 'Build/Products', arcname='Products')
        archive.add(ROOT / 'build/test-shards.json', arcname='test-shards.json')


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
        '-resultBundlePath', str(results),
        '-parallel-testing-enabled', 'NO', '-enableCodeCoverage', 'YES', '-test-timeouts-enabled', 'YES',
        '-default-test-execution-time-allowance', '180', '-maximum-test-execution-time-allowance', '240',
        *['-only-testing:' + test for test in tests], 'CODE_SIGNING_ALLOWED=NO']
    print(f'Running {shard}: {len(tests)} frozen test identifiers', flush=True)
    with prepared_simulator(shard) as sid:
        result = subprocess.run([*argv, '-destination', 'platform=iOS Simulator,id=' + sid], cwd=ROOT)
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
    parser.add_argument('action', choices=['build', 'compile', 'plan', 'pack', 'run'])
    parser.add_argument('--derived-data', type=Path, default=ROOT / 'build/DerivedData')
    parser.add_argument('--bundle', type=Path, default=ROOT / 'build/ci-testing')
    parser.add_argument('--shard')
    args = parser.parse_args()
    (ROOT / 'build').mkdir(exist_ok=True)
    try:
        if args.action in {'compile', 'build'}: compile_products(args.derived_data.resolve())
        if args.action in {'plan', 'build'}: plan_tests(args.derived_data.resolve())
        if args.action in {'pack', 'build'}: package_products(args.derived_data.resolve())
        if args.action == 'run': run_shard(args.bundle.resolve(), args.shard)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print('CI test error:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
