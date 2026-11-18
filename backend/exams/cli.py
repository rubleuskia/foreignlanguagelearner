"""Prepare and commit source-linked exam packages into explicit durable storage."""
import argparse
import json
from pathlib import Path
from .contract import ExamError
from .service import Service


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--storage-root',type=Path,required=True)
    parser.add_argument('--owner',required=True)
    commands=parser.add_subparsers(dest='command',required=True)
    prepare=commands.add_parser('dry-run'); prepare.add_argument('package_dir',type=Path)
    commit=commands.add_parser('commit'); commit.add_argument('--import-id',required=True)
    commit.add_argument('--transaction-id',required=True); commit.add_argument('--manifest-digest',required=True)
    commands.add_parser('catalog')
    args=parser.parse_args(argv)
    service=Service(args.storage_root)
    try:
        if args.command=='dry-run': result=service.dry_run(args.owner,args.package_dir)
        elif args.command=='commit': result=service.commit(args.owner,args.import_id,args.transaction_id,args.manifest_digest)
        else: result=service.catalog()
        print(json.dumps(result,ensure_ascii=False,indent=2))
        return 0
    except ExamError as error:
        print(json.dumps({'error':{'code':error.code,'details':error.details}},ensure_ascii=False))
        return 1


if __name__=='__main__': raise SystemExit(main())
