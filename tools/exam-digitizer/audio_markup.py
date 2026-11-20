#!/usr/bin/env python3
"""Locate repeated exam listening passages and run the existing subtitle aligner.

Input reference JSON deliberately separates the published text from recorded
occurrences: printed transcripts normally list repeated passages only once.
All timestamps are milliseconds relative to the untouched original MP3.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import math
import re
import shlex
import subprocess
import sys
import unicodedata
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2,
                                   allow_nan=False) + '\n', encoding='utf-8')


def tokens(text):
    # Search-only folding tolerates ASR accents. Published reference text and
    # grading answers are never normalized with this heuristic.
    folded = ''.join(c for c in unicodedata.normalize('NFD', text).casefold()
                     if not unicodedata.combining(c)).replace('ł', 'l')
    return re.findall(r'\w+', folded)


def timed_tokens(transcription):
    result = []
    for segment in transcription['segments']:
        for word in segment['words']:
            start, end = float(word['start']), float(word['end'])
            if not (math.isfinite(start) and math.isfinite(end) and 0 <= start <= end):
                raise ValueError('Recognition contains invalid word timestamps.')
            for token in tokens(word['word']):
                result.append({'token': token, 'start': start, 'end': end})
    return result


def find_anchor(words, phrase, expected_count, threshold=0.75, *, require_last_token=False):
    """Find independent repeated occurrences; fail rather than guess a count."""
    expected = tokens(phrase)
    if len(expected) < 3:
        raise ValueError('Anchors need at least three words.')
    actual = [w['token'] for w in words]
    candidates = []
    for start, token in enumerate(actual):
        first_exact = token == expected[0]
        if not first_exact and difflib.SequenceMatcher(
                None, expected[0], token, autojunk=False).ratio() < 0.66:
            continue
        best = None
        for length in range(max(3, len(expected) - 2), len(expected) + 3):
            end = start + length
            if end > len(actual):
                continue
            score = difflib.SequenceMatcher(None, expected, actual[start:end],
                                           autojunk=False).ratio()
            policy = 'token_sequence_with_first_token_typo_gate'
            # Exact concatenation tolerates ASR splitting one printed word.
            # It never rewrites source text or infers a word timestamp.
            if (len(''.join(expected)) >= 16
                    and ''.join(expected) == ''.join(actual[start:end])):
                score = 1.0
                policy = 'exact_concatenated_tokens'
            last_exact = actual[end-1] == expected[-1]
            if (require_last_token and policy != 'exact_concatenated_tokens'
                    and not last_exact and difflib.SequenceMatcher(
                        None, expected[-1], actual[end-1], autojunk=False).ratio() < 0.66):
                continue
            if require_last_token and policy != 'exact_concatenated_tokens':
                policy = 'token_sequence_with_endpoint_typo_gates'
            if best is None or score > best['score']:
                best = {'start': words[start]['start'], 'end': words[end-1]['end'],
                        'score': score, 'observed_text': ' '.join(actual[start:end]),
                        'reference_text': phrase, 'match_policy': policy,
                        'first_token_exact': first_exact,
                        'full_anchor_threshold': threshold}
                if require_last_token:
                    best.update(last_token_exact=last_exact, last_token_gate_required=True)
        if best and best['score'] >= threshold:
            candidates.append(best)
    # Candidates sharing recognized words are the same spoken occurrence,
    # even when a weak match starts across a long repeat/instruction pause.
    selected = []
    for candidate in sorted(candidates, key=lambda x: (x['score'], x['first_token_exact']), reverse=True):
        if all(abs(candidate['start'] - old['start']) > 20
               and (candidate['end'] <= old['start'] or old['end'] <= candidate['start'])
               for old in selected):
            selected.append(candidate)
    if len(selected) != expected_count:
        raise ValueError(f'Anchor {phrase!r}: expected {expected_count} occurrences, '
                         f'found {len(selected)} above {threshold}; review recognition.')
    return sorted(selected, key=lambda x: x['start'])


def locate(reference, transcription, duration_ms):
    words = timed_tokens(transcription)
    tasks = []
    previous_end = 0
    for task in reference['tasks']:
        count = task['expected_occurrences']
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            raise ValueError('Expected occurrence count must be a positive integer.')
        starts = find_anchor(words, task['start_anchor'], count)
        ends = find_anchor(words, task['end_anchor'], count, require_last_token=True)
        occurrences = []
        for number, (start, end) in enumerate(zip(starts, ends), 1):
            if not 0 <= start['start'] <= start['end'] <= end['end'] <= duration_ms / 1000:
                raise ValueError(f'Task {task["task_label"]} anchors exceed original audio bounds.')
            begin_ms = max(0, round(start['start'] * 1000) - 750)
            end_ms = min(duration_ms, round(end['end'] * 1000) + 750)
            if begin_ms < previous_end or not 3000 <= end_ms - begin_ms <= duration_ms:
                raise ValueError(f'Unusable or unordered task {task["task_label"]} interval.')
            previous_end = end_ms
            occurrences.append({
                'id': f'listening-{task["task_label"]}-{number}',
                'source_id': 'audio', 'start_ms': begin_ms, 'end_ms': end_ms,
                'role': 'primary' if number == 1 else 'repeat',
                'coverage': 'published_passage_including_example_excluding_instructions',
                'method': 'asr_text_anchors_then_existing_forced_aligner',
                'review_status': 'requires_listening_review',
                'evidence': {'start_anchor': start, 'end_anchor': end},
            })
        tasks.append({'task_label': task['task_label'],
                      'source_refs': task['source_refs'],
                      'occurrences': occurrences})
    return tasks


def run_command(command, **kwargs):
    print('Running: ' + shlex.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def probe(audio):
    result = run_command(['ffprobe', '-v', 'error', '-show_entries',
                          'format=duration', '-of', 'json', audio],
                         capture_output=True, text=True)
    return round(float(json.loads(result.stdout)['format']['duration']) * 1000)


def alignment_quality(data, reference_text):
    words = [w for s in data['alignment']['segments'] for w in s['words']]
    if not words:
        raise ValueError('Alignment contains no words.')
    return {'word_count': len(words),
            'untimed_word_count': len(data.get('untimed_words', [])),
            'requires_review': bool(data.get('requires_review')),
            'text_matches_reference': ' '.join(''.join(w['word'] for w in words).split())
            == ' '.join(reference_text.split()),
            'positive_word_fraction': sum(w['end'] > w['start'] for w in words) / len(words)}


def align_occurrences(args, reference, tasks, duration_ms):
    aligner = Path(args.aligner).resolve()
    if not aligner.is_file():
        raise ValueError(f'Missing existing aligner: {aligner}')
    evidence_root = args.output / 'evidence'
    evidence_root.mkdir()
    work_root = args.output / 'work'
    work_root.mkdir()
    for task, spec in zip(tasks, reference['tasks']):
        text_path = evidence_root / f'task-{task["task_label"]}.txt'
        text_path.write_text(spec['text'] + '\n', encoding='utf-8')
        for occurrence in task['occurrences']:
            name = occurrence['id']
            start_ms, end_ms = occurrence['start_ms'], occurrence['end_ms']
            wav = work_root / (name + '.wav')
            run_command(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                         '-ss', f'{start_ms/1000:.3f}', '-i', args.audio,
                         '-t', f'{(end_ms-start_ms)/1000:.3f}', '-ac', '1', '-ar', '16000', wav])
            result_folder = evidence_root / name
            command = [args.python, aligner, '--text', text_path, '--audio', wav,
                       '--language', 'pl', '--model', args.model, '--guided',
                       '--allow-untimed-words', '--output', result_folder]
            run_command(command)
            alignment_path = result_folder / 'alignment.json'
            data = json.loads(alignment_path.read_text())
            quality = alignment_quality(data, spec['text'])
            if not quality['text_matches_reference']:
                raise ValueError(f'Aligned reference text mismatch: {name}')
            occurrence['evidence']['alignment_path'] = 'alignment/' + str(alignment_path.relative_to(evidence_root))
            occurrence['evidence']['alignment_sha256'] = sha256(alignment_path)
            occurrence['evidence']['clip'] = {
                'derived_clip_sha256': sha256(wav),
                'original_source_id': 'audio', 'original_source_sha256': reference['audio']['sha256'],
                'original_start_ms': start_ms, 'original_end_ms': end_ms}
            occurrence['evidence']['quality'] = quality
            timed = [w for s in data['alignment']['segments'] for w in s['words']
                     if w['end'] > w['start']]
            occurrence['aligned_speech_start_ms'] = start_ms + round(timed[0]['start'] * 1000)
            occurrence['aligned_speech_end_ms'] = min(duration_ms, start_ms + round(timed[-1]['end'] * 1000))
            # Keep padded passage ranges: a source word with zero individual
            # duration is retained by the existing aligner, never silently cut.
            provenance = {'original_source': reference['audio'],
                          'source_refs': task['source_refs'],
                          'original_interval_ms': [start_ms, end_ms],
                          'reference_sha256': sha256(text_path),
                          'timestamp_coordinates': 'alignment word times are clip-relative seconds; '
                                                   'add original_interval_ms[0] for original MP3 milliseconds'}
            write_json(result_folder / 'provenance.json', provenance)
            print(f'Validated {name}: {quality}', flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--transcription', type=Path, required=True,
                        help='Raw Stable-ts transcription, with adjacent .provenance.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--aligner', type=Path, required=True)
    parser.add_argument('--python', type=Path, default=Path(sys.executable))
    parser.add_argument('--model', default='base')
    parser.add_argument('--locate-only', action='store_true',
                        help='Produce review-only anchor ranges without forced alignment')
    args = parser.parse_args(argv)
    try:
        reference = json.loads(args.reference.read_text())
        if sha256(args.audio) != reference['audio']['sha256']:
            raise ValueError('Original audio hash differs from reference.')
        provenance_path = args.transcription.with_suffix('.provenance.json')
        provenance = json.loads(provenance_path.read_text())
        if (provenance['audio_sha256'] != sha256(args.audio)
                or provenance['transcription_sha256'] != sha256(args.transcription)):
            raise ValueError('Cached transcription is not bound to this original MP3.')
        transcription = json.loads(args.transcription.read_text())
        duration_ms = probe(args.audio)
        tasks = locate(reference, transcription, duration_ms)
        args.output.mkdir(parents=True, exist_ok=False)
        if not args.locate_only:
            align_occurrences(args, reference, tasks, duration_ms)
        else:
            (args.output / 'evidence').mkdir()
        report = {
            'schema_version': 1, 'exam_id': reference['exam_id'],
            'source': dict(reference['audio'], duration_ms=duration_ms),
            'reference_source': reference['transcript'],
            'timestamp_unit': 'milliseconds_relative_to_original_audio',
            'review_status': 'requires_listening_review',
            'tasks': tasks,
            'report': {'task_count': len(tasks),
                       'occurrence_count': sum(len(t['occurrences']) for t in tasks),
                       'aligner': str(args.aligner), 'aligner_sha256': sha256(args.aligner),
                       'forced_alignment_executed': not args.locate_only,
                       'rough_transcription_sha256': sha256(args.transcription),
                       'reference_sha256': sha256(args.reference),
                       'human_listening_review_performed': False,
                       'limits': ['ASR/forced-alignment timing is a machine-generated proposal.',
                                  'Published text omits spoken instructions and repeat announcements.',
                                  'Occurrence ranges include examples and embedded pauses.',
                                  'Original full MP3 remains the exam-mode source of truth.']}}
        write_json(args.output / 'audio.json', report)
        write_json(args.output / 'evidence' / 'reference.json', reference)
        write_json(args.output / 'evidence' / 'transcription.provenance.json', provenance)
        write_json(args.output / 'evidence' / 'rough-transcription.json', transcription)
        print(json.dumps(report['report'], ensure_ascii=False, indent=2))
        print(f'Wrote {args.output / "audio.json"}', flush=True)
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
