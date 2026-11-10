#!/usr/bin/env python3
"""Measure real Polish alignment locally; never manufacture release acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


DRIVER = r'''
import json, os, resource, sys, time
from pathlib import Path
sys.path.insert(0, '/app/tools/subtitle-aligner')
import align
from worker.worker import probe_duration

started = time.monotonic()
audio = Path('/fixture/audio.wav')
allow_untimed = os.environ.get('BENCHMARK_ALLOW_UNTIMED_WORDS') == 'true'
result = {'qualityAccepted': False, 'costUsd': None, 'allowUntimedWords': allow_untimed}
try:
    duration = probe_duration(audio)
    if duration != 300:
        raise ValueError('Use an exactly 300-second fixture')
    result['audioSeconds'] = duration
    args = align.parser().parse_args([
        '--audio', str(audio), '--text', '/fixture/transcript.txt',
        '--output', '/result/alignment', '--language', 'pl',
        '--model', 'base', '--guided', '--device', 'cpu',
        '--model-dir', '/opt/models', '--format', 'both'] +
        (['--allow-untimed-words'] if allow_untimed else []))
    align.run(args)
    data = json.loads(Path('/result/alignment/alignment.json').read_text())
    words = [w for segment in data['alignment']['segments'] for w in segment['words']]
    result.update(success=True, words=len(words), untimedWords=len(data.get('untimed_words', [])),
                  requiresReview=data['requires_review'])
except Exception as error:
    result.update(success=False, errorType=type(error).__name__, error=str(error))
finally:
    result['runtimeSeconds'] = time.monotonic() - started
    peak = Path('/sys/fs/cgroup/memory.peak')
    result['peakMemoryMiB'] = int(peak.read_text()) / 1048576 if peak.exists() else None
    result['processPeakRssMiB'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    Path('/result/measurement.json').write_text(json.dumps(result, indent=2))
sys.exit(0 if result['success'] else 1)
'''


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True, help='Immutable repository@sha256:digest')
    parser.add_argument('--audio', type=Path, required=True, help='Matching 300-second PCM WAV')
    parser.add_argument('--text', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New local evidence directory')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--allow-untimed-words', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', args.image):
        parser.error('Use the immutable published image digest')
    if args.runs < 3:
        parser.error('At least three cold runs are required')
    if not args.audio.is_file() or not args.text.is_file() or args.audio.suffix != '.wav':
        parser.error('Provide real matching WAV and TXT files')
    args.output = args.output.resolve()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    driver = args.output / 'driver.py'
    driver.write_text(DRIVER)
    driver.chmod(0o644)
    architecture = subprocess.check_output(['docker', 'info', '--format', '{{.Architecture}}'], text=True).strip()
    report = {'scope': 'operator-pl-300-v1', 'image': args.image, 'environment': 'local-docker',
              'hostArchitecture': architecture, 'platform': 'linux/amd64', 'cpus': 2, 'memoryLimitMiB': 8192,
              'audioSha256': sha(args.audio), 'textSha256': sha(args.text),
              'qualityAccepted': False, 'costUsd': None, 'runs': [],
              'allowUntimedWords': args.allow_untimed_words,
              'note': 'Not a release acceptance report. Listening review, disk and actual cloud billing remain pending.'}
    for number in range(1, args.runs + 1):
        target = args.output / f'run-{number}'
        target.mkdir(mode=0o777)
        target.chmod(0o777)  # Container UID 65532 writes beneath a private evidence parent.
        started = time.monotonic()
        argv = ['docker', 'run', '--rm', '--platform', 'linux/amd64', '--network', 'none',
                '--cpus', '2', '--memory', '8g', '--memory-swap', '8g',
                '-e', 'OPERATOR_ALIGNMENT_PILOT=pl-300-v1', '-e', 'OMP_NUM_THREADS=2',
                '-e', 'BENCHMARK_ALLOW_UNTIMED_WORDS=' + str(args.allow_untimed_words).lower(),
                '-e', 'MKL_NUM_THREADS=2', '-e', 'AWS_EC2_METADATA_DISABLED=true',
                '--mount', f'type=bind,src={args.audio.resolve()},dst=/fixture/audio.wav,readonly',
                '--mount', f'type=bind,src={args.text.resolve()},dst=/fixture/transcript.txt,readonly',
                '--mount', f'type=bind,src={driver},dst=/benchmark.py,readonly',
                '--mount', f'type=bind,src={target},dst=/result',
                '--entrypoint', 'python', args.image, '/benchmark.py']
        with (target / 'private.log').open('w') as log:
            execution = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT)
        measurement = target / 'measurement.json'
        row = json.loads(measurement.read_text()) if measurement.exists() else {'success': False}
        row.update(exitCode=execution.returncode, containerWallSeconds=time.monotonic() - started)
        report['runs'].append(row)
        (args.output / 'local-measurements.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({'run': number, **row}), flush=True)
        if execution.returncode:
            raise SystemExit('Real alignment failed; inspect private.log. No acceptance report was produced.')


if __name__ == '__main__':
    main()
