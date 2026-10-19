#!/usr/bin/env python3
"""Preserve aligned word boundaries in a book, or upgrade a book from saved alignment JSON."""
import argparse
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import tempfile
import zipfile

import align

MAXIMUM_BYTES = 10_000_000
MAXIMUM_COMBINED_BYTES = 50_000_000


def subtitle_text(content):
    """Read the plain SRT/VTT text in the same order used by TranscriptParser."""
    segments = []
    for block in content.replace('\r\n', '\n').replace('\r', '\n').strip().split('\n\n'):
        lines = block.splitlines()
        timing = next((i for i, line in enumerate(lines) if '-->' in line), None)
        if timing is not None:
            body = '\n'.join(lines[timing + 1:])
            segments.append(html.unescape(re.sub(r'<[^>]+>', '', body)).strip())
    if not segments:
        raise ValueError('No subtitle cues for word timings.')
    return '\n\n'.join(segments)


def make_file(report, subtitle, track_id, audio_sha256, duration):
    if (not isinstance(duration, (float, int)) or isinstance(duration, bool)
            or not math.isfinite(duration) or duration <= 0
            or re.fullmatch(r'[0-9a-f]{64}', audio_sha256) is None):
        raise ValueError('Invalid audio duration or SHA-256.')
    if report.get('track_id', track_id) != track_id:
        raise ValueError('Alignment belongs to a different track.')
    fingerprint = report.get('fingerprint', {}).get('audio_sha256')
    if fingerprint is not None and fingerprint != audio_sha256:
        raise ValueError(f'Alignment audio hash mismatch for track {track_id}.')
    text = align.clean_text(subtitle_text(subtitle))
    expected = text.split()
    raw = [w for s in report['alignment']['segments'] for w in s['words']]
    words = []
    previous_end = 0.0
    offset = report.get('offset_seconds', 0)
    if not isinstance(offset, (int, float)) or isinstance(offset, bool) or not math.isfinite(offset):
        raise ValueError('Invalid timing offset.')
    for word in raw:
        token = align.clean_text(word['word'])
        if len(token.split()) != 1:
            raise ValueError('Alignment must contain one text token per word timing.')
        if not all(isinstance(word[k], (int, float)) and not isinstance(word[k], bool) for k in ('start', 'end')):
            raise ValueError('Word boundaries must be numeric seconds.')
        start, end = word['start'] + offset, word['end'] + offset
        if (not all(isinstance(t, (int, float)) and not isinstance(t, bool) and math.isfinite(t) for t in (start, end))
                or start < 0 or end < start or start + 0.000001 < previous_end or end > duration):
            raise ValueError(f'Invalid word boundary for track {track_id}: {token}.')
        previous_end = end
        words.append({'text': token, 'start': start, 'end': end})
    if [w['text'] for w in words] != expected:
        raise ValueError(f'Alignment text does not match subtitles for track {track_id}.')
    result = {'schemaVersion': 1, 'trackID': track_id, 'audioSHA256': audio_sha256,
              'textSHA256': hashlib.sha256(text.encode('utf-8')).hexdigest(), 'words': words}
    encoded = json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
    if len(encoded) > MAXIMUM_BYTES:
        raise ValueError(f'Word timings exceed 10 MB for track {track_id}.')
    return encoded


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def upgrade(book, alignment_directory, output, timings_only=False):
    """Use an unpacked book to avoid extracting or recompressing intermediate audio."""
    import batch_align
    if output.exists():
        raise ValueError('Output already exists; choose a new archive path.')
    manifest_path = book / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('format') != batch_align.FORMAT or manifest.get('schemaVersion') != 1:
        raise ValueError('Expected a schema-v1 book directory.')
    tracks = manifest.get('tracks', [])
    if not 1 <= len(tracks) <= 100 or len({t['id'] for t in tracks}) != len(tracks):
        raise ValueError('Book must contain 1–100 unique tracks.')
    extras = {}
    total_words = zero_words = 0
    for track in manifest['tracks']:
        if track['alignmentStatus'] == 'untimed':
            continue
        track_id = track['id']
        if re.fullmatch(r'[A-Za-z0-9_-]{1,64}', track_id) is None:
            raise ValueError('Invalid track identifier.')
        audio = batch_align.safe_path(book.resolve(), track['audio'], {'.mp3', '.m4a', '.wav'})
        subtitle = batch_align.safe_path(book.resolve(), track['subtitle'], {'.srt', '.vtt'})
        report = json.loads((alignment_directory / track_id / 'alignment.json').read_text(encoding='utf-8'))
        content = make_file(report, subtitle.read_text(encoding='utf-8-sig'), track_id,
                            file_hash(audio), batch_align.probe_audio(audio))
        name = f'word-timings/{track_id}.json'
        track['wordTimings'] = name
        extras[name] = content
        words = json.loads(content)['words']
        total_words += len(words)
        zero_words += sum(w['end'] == w['start'] for w in words)
    if not extras:
        raise ValueError('Book has no timed tracks to upgrade.')
    if sum(map(len, extras.values())) > MAXIMUM_COMBINED_BYTES:
        raise ValueError('Combined word timings exceed 50 MB.')
    output.parent.mkdir(parents=True, exist_ok=True)
    # A failed write cannot leave a seemingly usable final archive.
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        temporary_archive = Path(temporary) / 'book.zip'
        with zipfile.ZipFile(temporary_archive, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            names = {'manifest.json', manifest['transcript']}
            names.update(t['audio'] for t in manifest['tracks'])
            names.update(t['subtitle'] for t in manifest['tracks'] if t.get('subtitle'))
            for name in ([] if timings_only else sorted(names - {'manifest.json'})):
                source = batch_align.safe_path(book.resolve(), name)
                archive.write(source, name)
            archive.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False, indent=2))
            for name, content in extras.items():
                archive.writestr(name, content)
        # Link reserves the output name without overwriting a concurrently created file.
        os.link(temporary_archive, output)
    return {'tracks': len(extras), 'words': total_words, 'zero_duration_words': zero_words,
            'timing_bytes': sum(map(len, extras.values())), 'output': str(output)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--book', required=True, type=Path, help='Existing unpacked book directory (contains manifest.json)')
    parser.add_argument('--alignment-directory', required=True, type=Path, help='Directory containing <trackID>/alignment.json')
    parser.add_argument('--timings-only', action='store_true', help='Write a small update ZIP for an already imported book; omit audio and subtitles')
    parser.add_argument('--output', required=True, type=Path, help='New .book.zip; existing files are never overwritten')
    args = parser.parse_args()
    try:
        print(json.dumps(upgrade(args.book, args.alignment_directory, args.output, timings_only=args.timings_only), ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
