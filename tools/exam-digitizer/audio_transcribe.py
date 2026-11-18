#!/usr/bin/env python3
"""Create a source-bound Stable-ts rough transcript for exam audio markup."""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path


def digest(path):
    sha = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(data)
    return sha.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-url', required=True)
    parser.add_argument('--model', default='base')
    parser.add_argument('--language', default='pl')
    parser.add_argument('--threads', type=int, default=6)
    args = parser.parse_args(argv)
    if args.threads < 1:
        parser.error('--threads must be positive')
    try:
        if args.output.exists() or args.output.with_suffix('.provenance.json').exists():
            raise ValueError('Output already exists; choose a new file.')
        import torch
        import stable_whisper
        torch.set_num_threads(args.threads)
        started = time.monotonic()
        audio_sha256 = digest(args.audio)
        model = stable_whisper.load_model(args.model, device='cpu')
        result = model.transcribe(str(args.audio), language=args.language,
                                  fp16=False, verbose=False).to_dict()
        if not result.get('segments'):
            raise ValueError('Recognition returned no segments.')
        if digest(args.audio) != audio_sha256:
            raise ValueError('Original audio changed during recognition.')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                                          allow_nan=False)+'\n', encoding='utf-8')
        provenance = {
            'audio_sha256': audio_sha256,
            'transcription_sha256': digest(args.output),
            'audio_path': str(args.audio.resolve()), 'audio_url': args.source_url,
            'source_id': 'audio', 'model': args.model, 'language': args.language,
            'producer': f'stable_whisper {stable_whisper.__version__}',
            'torch_version': torch.__version__, 'device': 'cpu',
            'elapsed_seconds': round(time.monotonic()-started, 3),
            'review_status': 'machine_transcript_requires_review',
            'timestamp_unit': 'seconds_relative_to_original_audio',
        }
        args.output.with_suffix('.provenance.json').write_text(
            json.dumps(provenance, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(provenance, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, ImportError, RuntimeError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
