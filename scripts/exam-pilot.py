#!/usr/bin/env python3
"""Prepare and run the local exam pilot without exposing authentication tokens."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--storage-root', type=Path, required=True)
    sub = parser.add_subparsers(dest='action', required=True)
    importer = sub.add_parser('import')
    importer.add_argument('package', type=Path)
    serve = sub.add_parser('serve')
    serve.add_argument('--port', type=int, default=8774)
    launch = sub.add_parser('launch-simulator')
    launch.add_argument('--device', required=True)
    launch.add_argument('--app', type=Path, required=True)
    launch.add_argument('--port', type=int, default=8774)
    args = parser.parse_args()
    root = args.storage_root.resolve()
    if args.action == 'import':
        from backend.exams.service import Service
        service = Service(root)
        prepared = service.dry_run('local-pilot', args.package.resolve())
        result = service.commit('local-pilot', prepared['import_id'], str(uuid.uuid4()),
                                prepared['manifest_digest'])
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.action == 'serve':
        subprocess.run([sys.executable, '-m', 'backend.exams.server', '--storage-root', str(root),
                        '--port', str(args.port)], check=True)
    else:
        token = (root / '.local-api-token').read_text().strip()
        if len(token) < 32: parser.error('Start the local API first')
        subprocess.run(['xcrun', 'simctl', 'bootstatus', args.device, '-b'], check=True)
        subprocess.run(['xcrun', 'simctl', 'install', args.device, str(args.app.resolve())], check=True)
        env = {**os.environ, 'SIMCTL_CHILD_EXAM_API_URL': f'http://127.0.0.1:{args.port}',
               'SIMCTL_CHILD_EXAM_LOCAL_API_TOKEN': token}
        subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.device,
                        'com.rubleuskia.foreignlanguagelearner'], env=env, check=True)
        print('Launched the Debug app with the local authenticated exam API.')


if __name__ == '__main__': main()
