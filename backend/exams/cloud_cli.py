"""Explicit administrator publication. Dry-run is entirely local and read-only."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import tempfile

from .cloud_service import CloudService, preview
from .contract import ExamError
from .service import uid


def write_report(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                prefix=path.name + '.', suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--table', default=os.environ.get('EXAMS_TABLE'))
    parser.add_argument('--bucket', default=os.environ.get('EXAMS_BUCKET'))
    parser.add_argument('--region', default=os.environ.get('AWS_REGION', 'eu-north-1'))
    parser.add_argument('--profile')
    parser.add_argument('--owner', default='operator')
    commands = parser.add_subparsers(dest='command', required=True)
    dry = commands.add_parser('dry-run')
    dry.add_argument('package_dir', type=Path)
    commit = commands.add_parser('commit')
    commit.add_argument('package_dir', type=Path)
    commit.add_argument('--transaction-id', required=True)
    commit.add_argument('--manifest-digest', required=True)
    commit.add_argument('--report', type=Path, required=True,
                        help='Write publication receipt outside the repository; reuse transaction ID after interruption.')
    commands.add_parser('catalog')
    visibility = commands.add_parser('set-active')
    visibility.add_argument('exam_id')
    state = visibility.add_mutually_exclusive_group(required=True)
    state.add_argument('--active', dest='active', action='store_true')
    state.add_argument('--inactive', dest='active', action='store_false')
    args = parser.parse_args(argv)
    if args.command != 'dry-run' and (not args.table or not args.bucket):
        parser.error('--table and --bucket are required for cloud operations')
    if args.region != 'eu-north-1':
        parser.error('This project uses the selected Region eu-north-1')
    cloud_errors = ()
    try:
        if args.command == 'dry-run':
            result = preview(args.package_dir)
        else:
            if args.command == 'commit':
                uid(args.transaction_id)
                checked = preview(args.package_dir)
                if checked['manifest_digest'] != args.manifest_digest:
                    raise ExamError('EXAM_IMPORT_DIGEST_CONFLICT', 409)
                if args.report.exists():
                    prior = json.loads(args.report.read_text(encoding='utf-8'))
                    if not isinstance(prior, dict) or prior.get('transaction_id') != args.transaction_id:
                        raise ExamError('EXAM_IMPORT_REPORT_CONFLICT', 409)
            from botocore.exceptions import BotoCoreError, ClientError
            cloud_errors = (BotoCoreError, ClientError)
            service = CloudService.configured(args.table, args.bucket, region=args.region, profile=args.profile)
            if args.command == 'catalog':
                result = service.catalog()
            elif args.command == 'set-active':
                result = service.set_active(args.exam_id, args.active)
            else:
                result = service.publish(args.owner, args.package_dir, args.transaction_id, args.manifest_digest)
                write_report(args.report, {'transaction_id': args.transaction_id, 'result': result})
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except ExamError as error:
        print(json.dumps({'error': {'code': error.code, 'details': error.details}}, ensure_ascii=False))
        return 1
    except cloud_errors as error:
        code = getattr(error, 'response', {}).get('Error', {}).get('Code', type(error).__name__)
        print(json.dumps({'error': {'code': 'EXAM_CLOUD_OPERATION_FAILED', 'aws_code': code}}))
        return 1
    except (OSError, ValueError) as error:
        print(json.dumps({'error': {'code': 'EXAM_IMPORT_REPORT_ERROR', 'type': type(error).__name__}}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
