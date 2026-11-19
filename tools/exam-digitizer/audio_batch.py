#!/usr/bin/env python3
"""Resumable local rough ASR. This does not produce reviewed task alignments."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import threading
import time
import uuid


VERSION = 'exam-audio-batch/1.0'


def stamp():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def inside(root, relative):
    if not isinstance(relative, str) or Path(relative).is_absolute():
        raise ValueError('An artifact path must be relative')
    root = Path(root).resolve()
    result = (root / relative).resolve()
    if result == root or not result.is_relative_to(root):
        raise ValueError('Artifact path escapes its root')
    return result


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def run_lock(root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'audio-run.lock').open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another audio batch process already holds this directory') from None
        stream.seek(0); stream.truncate(); stream.write(str(os.getpid()) + '\n'); stream.flush()
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def load_jobs(batch_root, sources_root):
    index = json.loads((Path(batch_root) / 'batch-index.json').read_text())
    if index.get('schema_version') != '1.0' or Path(index['sources_root']).resolve() != Path(sources_root).resolve():
        raise ValueError('Unsupported batch index or source-root mismatch')
    jobs = index.get('jobs')
    if not isinstance(jobs, list) or not jobs:
        raise ValueError('Batch index has no jobs')
    ids, directories = set(), set()
    for job in jobs:
        if job.get('id') in ids or job.get('directory') in directories:
            raise ValueError('Duplicate batch job identity or directory')
        ids.add(job['id']); directories.add(job['directory'])
        inside(batch_root, job['directory'])
        inside(batch_root, job['directory'] + '/audio')
        source = job['sources']['audio']
        inside(sources_root, source['path'])
        if (not isinstance(source.get('sha256'), str) or len(source['sha256']) != 64
                or type(source.get('bytes')) is not int or source['bytes'] <= 0
                or not isinstance(source.get('url'), str) or not source['url'].startswith('https://')):
            raise ValueError('Invalid audio source identity')
    return jobs


def verified_source(sources_root, source):
    path = inside(sources_root, source['path'])
    if not path.is_file() or path.stat().st_size != source['bytes'] or digest(path) != source['sha256']:
        raise ValueError('Original audio differs from the download manifest')
    return path


def source_refs(source):
    return [{'source_id': 'audio', 'url': source['url'], 'sha256': source['sha256']}]


def duration_seconds(path):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', str(path)], check=True,
        text=True, capture_output=True, timeout=60)
    duration = float(result.stdout.strip())
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('Original audio has no valid duration')
    return duration


def recognition_quality(result, duration):
    if not isinstance(result, dict) or not isinstance(result.get('segments'), list) or not result['segments']:
        raise ValueError('Recognition returned no segments')
    issues = []
    previous_start = -1.0
    text_parts = []
    word_count = 0
    for position, segment in enumerate(result['segments']):
        if not isinstance(segment, dict) or not isinstance(segment.get('text'), str):
            raise ValueError('Malformed recognition segment')
        text_parts.append(segment['text'])
        word_count += len(segment.get('words') or [])
        start, end = segment.get('start'), segment.get('end')
        if (isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, (int, float))
                or not isinstance(end, (int, float)) or not math.isfinite(start) or not math.isfinite(end)):
            raise ValueError('Recognition timestamps must be finite numbers')
        if start < 0 or end <= start or end > duration + 0.5 or start < previous_start:
            issues.append({'segment_index': position, 'start': start, 'end': end,
                           'reason': 'bounds_or_order_requires_review'})
        previous_start = start
    if not ''.join(text_parts).strip():
        raise ValueError('Recognition returned only blank text')
    return {'segment_count': len(result['segments']), 'word_count': word_count,
            'duration_seconds': duration, 'timestamp_review_issues': issues,
            'review_status': 'machine_transcript_requires_review',
            'human_review_performed': False, 'forced_alignment_executed': False,
            'task_occurrences_verified': False}


def srt_text(result):
    def timing(seconds):
        ms = round(seconds * 1000)
        hours, ms = divmod(ms, 3600000)
        minutes, ms = divmod(ms, 60000)
        seconds, ms = divmod(ms, 1000)
        return f'{hours:02}:{minutes:02}:{seconds:02},{ms:03}'
    return '\n\n'.join(f"{number}\n{timing(segment['start'])} --> {timing(segment['end'])}\n{segment['text'].strip()}"
        for number, segment in enumerate(result['segments'], 1)) + '\n'


def validate_cache(folder, source, settings):
    folder = Path(folder)
    if folder.is_symlink() or (folder / 'artifact-manifest.json').is_symlink():
        raise ValueError('Existing ASR folders and manifests must not be symlinks')
    manifest = json.loads((folder / 'artifact-manifest.json').read_text())
    if (manifest.get('schema_version') != '1.0' or manifest.get('source_refs') != source_refs(source)
            or manifest.get('settings') != settings):
        raise ValueError('Existing ASR identity/settings differ; outputs were retained')
    rows = manifest.get('artifacts')
    if not isinstance(rows, list) or not rows:
        raise ValueError('Existing ASR manifest is empty')
    names = set()
    for row in rows:
        path = inside(folder, row['path'])
        if (row['path'] in names or row.get('source_refs') != source_refs(source)
                or not path.is_file() or path.stat().st_size != row['bytes'] or digest(path) != row['sha256']):
            raise ValueError('Existing ASR artifact differs; outputs were retained')
        names.add(row['path'])
    actual = {path.relative_to(folder).as_posix() for path in folder.rglob('*') if path.is_file()}
    if actual != names | {'artifact-manifest.json'}:
        raise ValueError('Existing ASR contains unlisted files; outputs were retained')
    required = {'rough-transcription.json', 'rough-transcription.provenance.json', 'rough-transcription.txt', 'quality-report.json'}
    if not required.issubset(names):
        raise ValueError('Existing ASR is incomplete')
    provenance = json.loads((folder / 'rough-transcription.provenance.json').read_text())
    if (provenance.get('audio_sha256') != source['sha256']
            or provenance.get('transcription_sha256') != digest(folder / 'rough-transcription.json')
            or provenance.get('timestamp_unit') != 'seconds_relative_to_original_audio'):
        raise ValueError('Existing ASR provenance does not bind the original recording')
    return json.loads((folder / 'quality-report.json').read_text())


class WhisperEngine:
    def __init__(self, model, threads):
        import stable_whisper
        import torch
        cached = Path.home() / '.cache' / 'whisper' / (model + '.pt')
        if not cached.is_file():
            raise ValueError('Cached local Whisper model is missing: ' + str(cached))
        torch.set_num_threads(threads)
        self.metadata = {'producer': 'stable_whisper ' + stable_whisper.__version__,
                         'torch_version': torch.__version__, 'device': 'cpu'}
        self.model = stable_whisper.load_model(model, device='cpu')

    def transcribe(self, path, language):
        return self.model.transcribe(str(path), language=language, fp16=False, verbose=False).to_dict()


class Batch:
    def __init__(self, batch_root, sources_root, *, model='base', language='pl', threads=6,
                 retry_invalid=False, engine_factory=WhisperEngine, probe=duration_seconds):
        self.root, self.sources = Path(batch_root).resolve(), Path(sources_root).resolve()
        self.settings = {'model': model, 'language': language, 'threads': threads, 'device': 'cpu'}
        self.retry_invalid = retry_invalid
        self.engine_factory, self.probe = engine_factory, probe
        self.engine = None
        self.progress_lock = threading.RLock()
        self.current_status = None
        self.run = {'schema_version': '1.0', 'generator': VERSION, 'pid': os.getpid(),
                    'state': 'starting', 'started_at': stamp(), 'updated_at': stamp(),
                    'settings': self.settings, 'completed': 0, 'cached': 0, 'existing_reviewed': 0,
                    'failed': 0, 'remaining': 0, 'current_job': None}

    def update(self, **changes):
        with self.progress_lock:
            self.run.update(changes, updated_at=stamp())
            atomic_json(self.root / 'audio-run-status.json', self.run)

    def status(self, folder, value):
        with self.progress_lock:
            snapshot = json.loads(json.dumps(value, allow_nan=False))
            snapshot.update(updated_at=stamp(), pid=os.getpid())
            atomic_json(folder / 'status.json', snapshot)
            self.current_status = (folder, snapshot) if snapshot['state'] == 'running' else None

    def heartbeat(self, stop):
        while not stop.wait(5):
            with self.progress_lock:
                self.update()
                if self.current_status:
                    folder, status = self.current_status
                    self.status(folder, status)

    def process(self, job):
        source = job['sources']['audio']
        path = verified_source(self.sources, source)
        folder = inside(self.root, job['directory'] + '/audio')
        folder.mkdir(parents=True, exist_ok=True)
        status = {'schema_version': '1.0', 'job_id': job['id'], 'state': 'running',
                  'started_at': stamp(), 'source_refs': source_refs(source),
                  'review_status': 'machine_transcript_requires_review',
                  'forced_alignment_executed': False, 'task_occurrences_verified': False}
        self.status(folder, status)
        attempt_id = uuid.uuid4().hex
        stage = folder / ('.stage-' + attempt_id)
        result_folder = folder / 'asr'
        try:
            if job.get('existing_package'):
                exam = json.loads((Path(job['existing_package']) / 'exam.json').read_text())
                audio = next(s for s in exam['sources'] if s['id'] == 'audio')
                if audio['sha256'] != source['sha256']:
                    raise ValueError('Existing reviewed package binds a different recording')
                status.update(state='existing_reviewed_package', existing_package=job['existing_package'],
                              exam_id=exam['id'], revision=exam['revision'])
                return 'existing_reviewed'
            if result_folder.exists():
                try:
                    quality = validate_cache(result_folder, source, self.settings)
                    status.update(state='completed_cached', quality=quality, artifact_directory='asr')
                    return 'cached'
                except (ValueError, KeyError, OSError, json.JSONDecodeError):
                    if not self.retry_invalid:
                        raise ValueError('ASR cache invalid; retained unchanged. Use --retry-invalid to quarantine and regenerate.') from None
                    result_folder.rename(folder / ('rejected-asr-' + attempt_id))
            if self.engine is None:
                self.update(state='loading_model')
                self.engine = self.engine_factory(self.settings['model'], self.settings['threads'])
                self.update(state='running')
            duration = self.probe(path)
            started = time.monotonic()
            result = self.engine.transcribe(path, self.settings['language'])
            verified_source(self.sources, source)
            quality = recognition_quality(result, duration)
            stage.mkdir()
            atomic_json(stage / 'rough-transcription.json', result)
            text = '\n'.join(segment['text'].strip() for segment in result['segments']) + '\n'
            (stage / 'rough-transcription.txt').write_text(text, encoding='utf-8')
            if not quality['timestamp_review_issues']:
                (stage / 'rough-transcription.srt').write_text(srt_text(result), encoding='utf-8')
            provenance = {'schema_version': '1.0', 'generator': VERSION, **self.settings,
                **self.engine.metadata, 'audio_sha256': source['sha256'], 'audio_path': str(path),
                'audio_url': source['url'], 'source_id': 'audio', 'source_refs': source_refs(source),
                'transcription_sha256': digest(stage / 'rough-transcription.json'),
                'timestamp_unit': 'seconds_relative_to_original_audio',
                'elapsed_seconds': round(time.monotonic() - started, 3),
                'review_status': 'machine_transcript_requires_review',
                'forced_alignment_executed': False, 'task_occurrences_verified': False,
                'human_review_performed': False}
            atomic_json(stage / 'rough-transcription.provenance.json', provenance)
            atomic_json(stage / 'quality-report.json', quality)
            rows = [{'path': p.name, 'bytes': p.stat().st_size, 'sha256': digest(p),
                     'source_refs': source_refs(source)} for p in sorted(stage.iterdir()) if p.is_file()]
            atomic_json(stage / 'artifact-manifest.json', {'schema_version': '1.0', 'generator': VERSION,
                'settings': self.settings, 'source_refs': source_refs(source), 'artifacts': rows})
            validate_cache(stage, source, self.settings)
            stage.rename(result_folder)
            status.update(state='completed_requires_review', quality=quality, artifact_directory='asr',
                          elapsed_seconds=provenance['elapsed_seconds'])
            return 'completed'
        except BaseException as error:
            status.update(state='interrupted' if isinstance(error, (KeyboardInterrupt, SystemExit)) else 'failed',
                          error=f'{type(error).__name__}: {error}')
            raise
        finally:
            if stage.exists(): shutil.rmtree(stage)
            status['ended_at'] = stamp()
            self.status(folder, status)
            atomic_json(folder / 'attempts' / (attempt_id + '.json'), status)

    def execute(self):
        with run_lock(self.root):
            jobs = load_jobs(self.root, self.sources)
            self.update(state='running', total=len(jobs), remaining=len(jobs))
            stop = threading.Event()
            thread = threading.Thread(target=self.heartbeat, args=(stop,), daemon=True)
            thread.start()
            try:
                for number, job in enumerate(jobs):
                    self.update(current_job=job['id'], remaining=len(jobs) - number)
                    try:
                        state = self.process(job)
                    except (ValueError, OSError, RuntimeError, ImportError, KeyError, StopIteration, subprocess.SubprocessError) as error:
                        state = 'failed'
                        # Source failures can precede process()'s status creation.
                        folder = inside(self.root, job['directory'] + '/audio')
                        self.status(folder, {'schema_version': '1.0', 'job_id': job['id'], 'state': 'failed',
                            'error': f'{type(error).__name__}: {error}', 'ended_at': stamp(),
                            'source_refs': source_refs(job['sources']['audio'])})
                    self.update(**{state: self.run[state] + 1}, remaining=len(jobs) - number - 1)
                    print(json.dumps({'job_id': job['id'], 'state': state, 'remaining': self.run['remaining']}, ensure_ascii=False), flush=True)
                self.update(state='completed_with_failures' if self.run['failed'] else 'completed',
                            current_job=None, ended_at=stamp())
            except BaseException:
                self.update(state='interrupted', ended_at=stamp())
                raise
            finally:
                stop.set(); thread.join()
        return 1 if self.run['failed'] else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch-root', required=True, type=Path)
    parser.add_argument('--sources-root', required=True, type=Path)
    parser.add_argument('--model', default='base')
    parser.add_argument('--language', default='pl')
    parser.add_argument('--threads', default=6, type=int)
    parser.add_argument('--retry-invalid', action='store_true')
    args = parser.parse_args(argv)
    if args.threads < 1: parser.error('--threads must be positive')
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return Batch(args.batch_root, args.sources_root, model=args.model, language=args.language,
                     threads=args.threads, retry_invalid=args.retry_invalid).execute()
    except KeyboardInterrupt:
        return 130
    except (ValueError, OSError, RuntimeError, ImportError, KeyError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__': sys.exit(main())
