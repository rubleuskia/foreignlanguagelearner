#!/usr/bin/env python3
"""Resumable archive evidence extraction. Extracted evidence is not a reviewed exam."""
import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import multiprocessing
import os
from pathlib import Path
import re
import shutil
import sys
import uuid

from exam_digitizer import ROLES, digest, extract_evidence, inside, select_sources


def stamp():
    return datetime.now(timezone.utc).isoformat()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def lock(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with Path(path).open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def binding(job):
    return [{'source_id': role, 'url': entry['url'], 'sha256': entry['sha256']}
            for role, entry in sorted(job['sources'].items())]


def priority(selection):
    months = {'stycznia': 1, 'lutego': 2, 'marca': 3, 'kwietnia': 4, 'maja': 5,
              'czerwca': 6, 'lipca': 7, 'sierpnia': 8, 'września': 9,
              'października': 10, 'listopada': 11, 'grudnia': 12}
    # This affects scheduling only. Original source labels/dates are never rewritten.
    level = selection['level']
    order = 0 if level == 'B1' else 1 if level == 'B2' else 2 if level in {'C1', 'C2'} else 3
    month = next((value for name, value in months.items() if name in selection['session']), 0)
    day = int(re.search(r'\d+', selection['session']).group())
    return order, -int(selection['year']), -month, -day, level


def initialize(sources_root, batch_root):
    sources_root, batch_root = Path(sources_root).resolve(), Path(batch_root).resolve()
    manifest_path = sources_root / 'manifest.json'
    manifest = read(manifest_path)
    groups = {}
    for entry in manifest['entries']:
        role = ROLES.get(entry.get('kind'))
        if not role:
            continue
        selection = {'year': str(entry['year']), 'session': entry['session'], 'level': entry['level']}
        key = tuple(selection.values())
        group = groups.setdefault(key, {'selection': selection, 'sources': {}})
        if role in group['sources']:
            raise ValueError('Duplicate source role: ' + str(key))
        inside(sources_root, entry['path'])
        group['sources'][role] = entry
    existing = {}
    for file in (sources_root / 'generated').glob('*/exam.json'):
        exam = read(file)
        if not exam.get('revision'):
            continue
        identities = tuple(sorted((s['id'], s['sha256']) for s in exam['sources']))
        existing[identities] = str(file.parent.resolve())
    jobs = []
    for group in sorted(groups.values(), key=lambda value: priority(value['selection'])):
        if set(group['sources']) != {'paper', 'keys', 'audio'}:
            raise ValueError('Incomplete source group: ' + str(group['selection']))
        path = Path(group['sources']['paper']['path'])
        if path.parts[0] != 'originals' or len(path.parts) != 5:
            raise ValueError('Unexpected original archive path: ' + str(path))
        directory = Path(*path.parts[1:-1]).as_posix()
        inside(batch_root, directory)
        identities = tuple(sorted((role, entry['sha256']) for role, entry in group['sources'].items()))
        jobs.append({'id': directory, 'directory': directory, **group,
                     'existing_package': existing.get(identities)})
    if len({job['id'] for job in jobs}) != len(jobs):
        raise ValueError('Duplicate batch output directory')
    index = {'schema_version': '1.0', 'created_at': stamp(), 'sources_root': str(sources_root),
             'source_manifest_sha256': digest(manifest_path), 'jobs': jobs}
    with lock(batch_root / '.index.lock'):
        target = batch_root / 'batch-index.json'
        if target.exists():
            previous = read(target)
            for key in ('sources_root', 'source_manifest_sha256'):
                if previous.get(key) != index[key]:
                    raise ValueError('Batch source identity differs; choose a new batch directory')
            return previous
        write(target, index)
    return index


def verify_evidence(job_root, job):
    manifest = read(Path(job_root) / 'evidence/artifact-manifest.json')
    if manifest.get('source_refs') != binding(job):
        raise ValueError('Completed evidence has different source identities')
    declared = set()
    for row in manifest['artifacts']:
        file = inside(job_root, row['path'])
        if not file.is_file() or file.stat().st_size != row['bytes'] or digest(file) != row['sha256']:
            raise ValueError('Evidence artifact failed integrity: ' + row['path'])
        declared.add(row['path'])
    actual = {p.relative_to(job_root).as_posix() for p in (Path(job_root) / 'evidence').rglob('*')
              if p.is_file() and p.name != 'artifact-manifest.json'}
    if actual != declared:
        raise ValueError('Evidence contains undeclared artifacts')
    return manifest


def extract_one(sources_root, batch_root, job, render):
    job_root = inside(batch_root, job['directory'])
    status_path = job_root / 'evidence-status.json'
    source_refs = binding(job)
    with lock(job_root / '.evidence.lock'):
        try:
            selected = select_sources(sources_root, job['selection'])
            if (job_root / 'evidence').exists():
                manifest = verify_evidence(job_root, job)
                result = {'state': 'evidence_ready', 'cached': True,
                          'page_count': manifest['page_count'], 'rendered': manifest['rendered']}
                if render and not manifest['rendered']:
                    raise ValueError('Existing evidence omits rendering; choose a separate batch directory')
            else:
                write(status_path, {'state': 'running', 'started_at': stamp(), 'pid': os.getpid(),
                                    'source_refs': source_refs, 'selection': job['selection']})
                stage = job_root / ('.evidence-stage-' + uuid.uuid4().hex)
                stage.mkdir()
                try:
                    documents = extract_evidence(selected, stage, render=render)
                    candidates = []
                    for doc in documents:
                        for page in doc['pages']:
                            headings = [line.strip() for line in page['text'].splitlines()
                                if re.match(r'^\s*(?:[IVXL]+\.\s|ROZUMIENIE|POPRAWNOŚĆ|PISANIE|MÓWIENIE)', line)]
                            if headings:
                                candidates.append({'source_id': doc['source_id'], 'page': page['page'],
                                    'headings': headings, 'source_refs': page['source_refs']})
                    write(stage / 'structure-draft.json', {
                        'status': 'requires_structure_review', 'reviewed_import': False,
                        'note': 'Heading candidates and complete page text; no inferred questions or keys.',
                        'selection': job['selection'], 'source_refs': source_refs, 'pages': candidates})
                    page_refs = {row['path']: row['source_refs'] for row in read(stage / 'page-index.json')['pages']}
                    artifacts = []
                    for file in sorted(stage.rglob('*')):
                        if not file.is_file(): continue
                        path = 'evidence/' + file.relative_to(stage).as_posix()
                        artifacts.append({'path': path, 'bytes': file.stat().st_size, 'sha256': digest(file),
                                          'source_refs': page_refs.get(path, source_refs)})
                    manifest = {'schema_version': '1.0', 'selection': job['selection'],
                        'source_refs': source_refs, 'reviewed_import': False, 'rendered': render,
                        'page_count': sum(len(doc['pages']) for doc in documents), 'artifacts': artifacts}
                    write(stage / 'artifact-manifest.json', manifest)
                    stage.rename(job_root / 'evidence')
                    result = {'state': 'evidence_ready', 'cached': False,
                              'page_count': manifest['page_count'], 'rendered': render}
                finally:
                    if stage.exists(): shutil.rmtree(stage)
            result.update(finished_at=stamp(), source_refs=source_refs, reviewed_import=False,
                          selection=job['selection'], id=job['id'])
            write(status_path, result)
            return result
        except Exception as error:
            result = {'id': job['id'], 'state': 'failed', 'error': str(error), 'finished_at': stamp(),
                      'selection': job['selection'], 'source_refs': source_refs, 'reviewed_import': False}
            write(status_path, result)
            return result


def evidence(sources_root, batch_root, workers=2, render=True):
    batch_root = Path(batch_root).resolve()
    index = initialize(sources_root, batch_root)
    jobs = [job for job in index['jobs'] if not job['existing_package']]
    with lock(batch_root / '.evidence-run.lock'):
        started = stamp()
        results = []
        def publish(state):
            write(batch_root / 'evidence-run-status.json', {
                'state': state, 'pid': os.getpid(), 'started_at': started, 'updated_at': stamp(),
                'job_count': len(jobs), 'completed': len(results),
                'failed': sum(row['state'] == 'failed' for row in results),
                'existing_packages': sum(bool(job['existing_package']) for job in index['jobs']),
                'source_manifest_sha256': index['source_manifest_sha256'],
                'reviewed_imports_produced': 0})
        publish('running')
        with ProcessPoolExecutor(max_workers=workers, mp_context=multiprocessing.get_context('spawn')) as pool:
            pending = {pool.submit(extract_one, sources_root, batch_root, job, render): job for job in jobs}
            for future in as_completed(pending):
                try:
                    result = future.result()
                except Exception as error:
                    job = pending[future]
                    result = {'id': job['id'], 'state': 'failed', 'error': str(error),
                              'source_refs': binding(job), 'finished_at': stamp(), 'reviewed_import': False}
                    write(inside(batch_root, job['directory']) / 'evidence-status.json', result)
                results.append(result); publish('running')
                print(json.dumps({key: result.get(key) for key in ('id', 'state', 'page_count', 'cached', 'error')}, ensure_ascii=False), flush=True)
        publish('completed_with_errors' if any(row['state'] == 'failed' for row in results) else 'completed')
        return 1 if any(row['state'] == 'failed' for row in results) else 0


def status(batch_root):
    batch_root = Path(batch_root).resolve()
    index = read(batch_root / 'batch-index.json')
    curation = None
    curation_path = inside(batch_root, 'curation-index.json')
    if curation_path.exists():
        curation = read(curation_path)
        if curation.get('source_manifest_sha256') != index['source_manifest_sha256']:
            raise ValueError('Curation snapshot refers to another source archive')
    stages = {}
    for name in ('evidence-run-status.json', 'audio-run-status.json'):
        if (batch_root / name).exists(): stages[name] = read(batch_root / name)
    rows = []
    for job in index['jobs']:
        row = {'id': job['id'], 'selection': job['selection'], 'existing_package': job['existing_package']}
        for key, relative in [('evidence', 'evidence-status.json'), ('audio', 'audio/status.json')]:
            file = inside(batch_root, job['directory']) / relative
            if file.exists(): row[key] = read(file)
        rows.append(row)
    return {'schema_version': '1.0', 'job_count': len(rows), 'runs': stages,
            'curation': curation, 'jobs': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['init', 'evidence', 'status'])
    parser.add_argument('--sources-root', type=Path, default=Path('/Users/arublevsky/dev/ExamSources'))
    parser.add_argument('--batch-root', type=Path, required=True)
    parser.add_argument('--workers', type=int, default=2, choices=range(1, 5))
    parser.add_argument('--no-render', action='store_true')
    args = parser.parse_args()
    if args.action == 'evidence':
        return evidence(args.sources_root, args.batch_root, args.workers, not args.no_render)
    value = initialize(args.sources_root, args.batch_root) if args.action == 'init' else status(args.batch_root)
    print(json.dumps(value, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
