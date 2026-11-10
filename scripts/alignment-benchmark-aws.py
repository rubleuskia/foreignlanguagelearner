#!/usr/bin/env python3
"""Run three measurements on an already reviewed/deployed private benchmark stack."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import time
import uuid

import boto3
from botocore.config import Config


PREFIX = r'''
import contextlib, hashlib, json, os, signal, threading
from pathlib import Path
import boto3
from botocore.config import Config
s3 = boto3.client('s3', region_name='eu-north-1', config=Config(connect_timeout=5, read_timeout=30, retries={'total_max_attempts': 2}))
bucket = os.environ['BENCHMARK_BUCKET']
root = Path('/tmp/result'); root.mkdir()
fixture = Path('/tmp/fixture'); fixture.mkdir()
for key, name in [('audio.wav', 'AUDIO'), ('transcript.txt', 'TEXT')]:
    path = fixture / key
    s3.download_file(bucket, 'input/' + key, str(path))
    assert hashlib.sha256(path.read_bytes()).hexdigest() == os.environ['BENCHMARK_' + name + '_SHA256']
disk = []
done = threading.Event()
def sample():
    while not done.is_set():
        stat = os.statvfs('/tmp')
        disk.append((stat.f_blocks-stat.f_bfree)*stat.f_frsize/1048576)
        done.wait(1)
threading.Thread(target=sample, daemon=True).start()
def timeout(*_):
    raise TimeoutError('Benchmark inference exceeded 15 minutes')
signal.signal(signal.SIGALRM, timeout)
signal.alarm(900)
try:
    with (root / 'private.log').open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
'''

SUFFIX = r'''
finally:
    signal.alarm(0)
    done.set()
    path = root / 'measurement.json'
    if path.exists():
        data = json.loads(path.read_text())
        data['peakDiskUsedMiB'] = max(disk) if disk else None
        fallback = Path('/sys/fs/cgroup/memory/memory.max_usage_in_bytes')
        if data.get('peakMemoryMiB') is None and fallback.exists():
            data['peakMemoryMiB'] = int(fallback.read_text()) / 1048576
        path.write_text(json.dumps(data, indent=2))
    for path in root.rglob('*'):
        if path.is_file():
            s3.upload_file(str(path), bucket, 'results/' + os.environ['BENCHMARK_RUN_ID'] + '/' + str(path.relative_to(root)))
'''


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cloud_driver():
    source = Path(__file__).with_name('alignment-benchmark-local.py')
    spec = importlib.util.spec_from_file_location('local_benchmark', source)
    local = importlib.util.module_from_spec(spec); spec.loader.exec_module(local)
    engine = local.DRIVER.replace('/fixture/', '/tmp/fixture/').replace('/result/', '/tmp/result/')
    driver = PREFIX + '\n'.join('        ' + line for line in engine.splitlines()) + '\n' + SUFFIX
    compile(driver, '<cloud-benchmark-driver>', 'exec')
    return driver


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stack', default='ForeignLanguageLearnerAudioBenchmark')
    parser.add_argument('--project', required=True)
    parser.add_argument('--profile', default='fll-control')
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--text', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.audio.is_file() or not args.text.is_file():
        parser.error('Provide matching real audio/text fixtures')
    session = boto3.Session(profile_name=args.profile, region_name='eu-north-1')
    config = Config(connect_timeout=5, read_timeout=30, retries={'total_max_attempts': 2})
    sts, cf, ecs, s3 = (session.client(name, config=config) for name in ('sts', 'cloudformation', 'ecs', 's3'))
    if sts.get_caller_identity()['Account'] != args.project:
        raise ValueError('Selected AWS project does not match')
    stack = cf.describe_stacks(StackName=args.stack)['Stacks'][0]
    if {'Key': 'Purpose', 'Value': 'fll-audio-benchmark'} not in stack.get('Tags', []):
        raise ValueError('Not a disposable audio benchmark stack')
    out = {row['OutputKey']: row['OutputValue'] for row in stack['Outputs']}
    if f':eu-north-1:{args.project}:' not in out['Cluster']:
        raise ValueError('Benchmark cluster belongs to another project/Region')
    for state in ['RUNNING', 'PENDING']:
        for page in ecs.get_paginator('list_tasks').paginate(cluster=out['Cluster'], desiredStatus=state):
            if page.get('taskArns'): raise ValueError('Another benchmark is active; do not overwrite its inputs')
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    driver = cloud_driver()
    driver_path = args.output / 'driver.py'; driver_path.write_text(driver)
    for path, key in [(args.audio, 'audio.wav'), (args.text, 'transcript.txt'), (driver_path, 'driver.py')]:
        s3.upload_file(str(path), out['Bucket'], 'input/' + key)
    summary = {'workerImageDigest': out['ImageDigest'], 'scope': 'operator-pl-300-v1',
               'maxAudioSeconds': 300, 'qualityAccepted': False, 'costUsd': None,
               'stackId': stack['StackId'], 'project': args.project, 'bucket': out['Bucket'],
               'audioSha256': sha(args.audio), 'textSha256': sha(args.text), 'runs': []}
    (args.output / 'aws-measurements.json').write_text(json.dumps(summary, indent=2))
    for number in range(1, 4):
        run = str(uuid.uuid4())
        env = [{'name': 'BENCHMARK_RUN_ID', 'value': run}]
        env += [{'name': 'BENCHMARK_' + name + '_SHA256', 'value': sha(path)}
                for name, path in [('AUDIO', args.audio), ('TEXT', args.text), ('DRIVER', driver_path)]]
        task = None
        try:
            result = ecs.run_task(cluster=out['Cluster'], taskDefinition=out['TaskDefinition'],
                launchType='FARGATE', platformVersion='1.4.0', count=1, clientToken=run, startedBy=run,
                networkConfiguration={'awsvpcConfiguration': {'subnets': [out['Subnet']],
                    'securityGroups': [out['SecurityGroup']], 'assignPublicIp': 'ENABLED'}},
                overrides={'containerOverrides': [{'name': 'Measurement', 'environment': env}]})
            if result.get('failures') or len(result.get('tasks', [])) != 1:
                raise RuntimeError('ECS did not start exactly one measurement task')
            task = result['tasks'][0]['taskArn']
            deadline = time.monotonic() + 20 * 60
            while True:
                current = ecs.describe_tasks(cluster=out['Cluster'], tasks=[task])['tasks'][0]
                if current['lastStatus'] == 'STOPPED': break
                if time.monotonic() > deadline: raise TimeoutError('Benchmark task exceeded 20-minute controller limit')
                time.sleep(15)
            folder = args.output / f'run-{number}'; folder.mkdir()
            (folder / 'task.json').write_text(json.dumps(current, default=str, indent=2))
            for page in s3.get_paginator('list_objects_v2').paginate(Bucket=out['Bucket'], Prefix='results/' + run + '/'):
                for row in page.get('Contents', []):
                    relative = Path(row['Key']).relative_to('results/' + run)
                    if '..' in relative.parts: raise ValueError('Invalid result path')
                    target = folder / relative; target.parent.mkdir(parents=True, exist_ok=True)
                    s3.download_file(out['Bucket'], row['Key'], str(target))
            measurement = folder / 'measurement.json'
            row = json.loads(measurement.read_text()) if measurement.exists() else {
                'success': False, 'error': 'No engine measurement; inspect retained task.json and task logs'}
            if current.get('pullStartedAt') and current.get('stoppedAt'):
                row['taskBilledSeconds'] = max(60, math.ceil((current['stoppedAt']-current['pullStartedAt']).total_seconds()))
            summary['runs'].append(row)
            (args.output / 'aws-measurements.json').write_text(json.dumps(summary, indent=2))
            print(json.dumps({'run': number, **row}), flush=True)
            if not row.get('success') or any(c.get('exitCode') != 0 for c in current['containers']):
                raise RuntimeError('Real measurement failed; results retained, no automatic retry')
        finally:
            if task:
                current = ecs.describe_tasks(cluster=out['Cluster'], tasks=[task])['tasks'][0]
                folder = args.output / f'run-{number}'; folder.mkdir(exist_ok=True)
                (folder / 'task.json').write_text(json.dumps(current, default=str, indent=2))
                if current['lastStatus'] != 'STOPPED':
                    ecs.stop_task(cluster=out['Cluster'], task=task, reason='Measurement controller cleanup')


if __name__ == '__main__':
    main()
