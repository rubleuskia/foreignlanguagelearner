#!/usr/bin/env python3
"""Audit exam passage bounds, forced-alignment coverage and repeated waveforms."""
import argparse
import hashlib
import json
import wave
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_wave(path):
    import numpy as np
    with wave.open(str(path), 'rb') as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) != (1, 2, 16000):
            raise ValueError('Expected mono PCM16 at 16kHz.')
        # Decimate for waveform-comparison only; the aligner receives 16kHz.
        return np.frombuffer(stream.readframes(stream.getnframes()), dtype='<i2')[::2].astype('float64')


def waveform_probe(primary, repeated, position, sr=8000):
    import numpy as np
    from scipy.signal import correlate
    width = 8 * sr
    template_start = round(position * sr)
    template = primary[template_start:template_start+width]
    search_start = max(0, template_start - 2 * sr)
    search_end = min(len(repeated), template_start + width + 2 * sr)
    search = repeated[search_start:search_end]
    if len(template) != width or len(search) < width:
        raise ValueError('Passage is too short for repeat verification.')
    correlation = correlate(search, template, mode='valid', method='fft')
    best = int(np.argmax(correlation))
    observed = search[best:best+width]
    left = template-template.mean()
    right = observed-observed.mean()
    denominator = np.linalg.norm(left) * np.linalg.norm(right)
    score = float(np.dot(left, right) / denominator) if denominator else 0.
    return {'correlation': round(score, 8),
            'primary_local_start_ms': round(template_start / sr * 1000),
            'repeat_local_start_ms': round((search_start + best) / sr * 1000),
            'duration_ms': 8000}


def audit(folder):
    audio_path = folder / 'audio.json'
    audio = json.loads(audio_path.read_text())
    evidence = folder / 'evidence'
    reference = json.loads((evidence / 'reference.json').read_text())
    task_results = []
    all_occurrences = []
    word_count = untimed_count = 0
    for task, spec in zip(audio['tasks'], reference['tasks']):
        occurrences = task['occurrences']
        task_report = {'task_label': task['task_label'], 'source_refs': task['source_refs'],
                       'expected_occurrences': spec['expected_occurrences'],
                       'observed_occurrences': len(occurrences), 'occurrences': []}
        if len(occurrences) != spec['expected_occurrences']:
            raise ValueError('Missing repeated passage.')
        for index, occurrence in enumerate(occurrences):
            all_occurrences.append(occurrence)
            alignment_path = evidence / occurrence['id'] / 'alignment.json'
            alignment = json.loads(alignment_path.read_text())
            quality = occurrence['evidence']['quality']
            word_count += quality['word_count']
            untimed_count += quality['untimed_word_count']
            report = {'id': occurrence['id'], 'start_ms': occurrence['start_ms'],
                      'end_ms': occurrence['end_ms'],
                      'official_text_matches': quality['text_matches_reference'],
                      'word_count': quality['word_count'],
                      'untimed_word_count': quality['untimed_word_count'],
                      'untimed_percentage': round(100 * quality['untimed_word_count']/quality['word_count'], 3),
                      'start_anchor_score': occurrence['evidence']['start_anchor']['score'],
                      'end_anchor_score': occurrence['evidence']['end_anchor']['score']}
            if not quality['text_matches_reference']:
                raise ValueError('Official text differs from the aligned text.')
            # Every subtitle/normalised-text artifact has a verifiable source
            # chain, even when its own format cannot carry source metadata.
            provenance_path = alignment_path.with_name('provenance.json')
            provenance = json.loads(provenance_path.read_text())
            provenance['reference_source'] = audio['reference_source']
            provenance['generated_artifacts'] = [
                {'path': 'alignment/' + str(p.relative_to(evidence)), 'sha256': digest(p)}
                for p in sorted(alignment_path.parent.iterdir()) if p.name != 'provenance.json']
            provenance_path.write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+'\n')
            if index:
                first = occurrences[0]
                primary = read_wave(folder / 'work' / (first['id'] + '.wav'))
                repeated = read_wave(folder / 'work' / (occurrence['id'] + '.wav'))
                probes = [waveform_probe(primary, repeated, 3),
                          waveform_probe(primary, repeated, len(primary)/8000 - 12)]
                for probe in probes:
                    probe['primary_original_start_ms'] = first['start_ms'] + probe['primary_local_start_ms']
                    probe['repeat_original_start_ms'] = occurrence['start_ms'] + probe['repeat_local_start_ms']
                    probe['repeat_offset_ms'] = probe['repeat_original_start_ms'] - probe['primary_original_start_ms']
                agrees = abs(probes[0]['repeat_offset_ms'] - probes[1]['repeat_offset_ms']) <= 25
                passed = min(p['correlation'] for p in probes) >= .98 and agrees
                report['repeat_waveform'] = {'status': 'passed' if passed else 'requires_review',
                                            'probes': probes, 'offset_consistent_within_25ms': agrees}
                occurrence['evidence']['repeat_waveform'] = report['repeat_waveform']
            task_report['occurrences'].append(report)
        text_path = evidence / f'task-{task["task_label"]}.txt'
        text_path.with_suffix('.provenance.json').write_text(json.dumps({
            'source': audio['reference_source'], 'source_refs': task['source_refs'],
            'artifact_path': 'alignment/' + text_path.name, 'artifact_sha256': digest(text_path),
            'text_corrections': spec.get('text_corrections', []),
            'note': 'Speaker labels, item numbers and PDF decoration are excluded from forced-alignment input.'
        }, ensure_ascii=False, indent=2)+'\n')
        task_results.append(task_report)
    bounds_valid = all(0 <= o['start_ms'] < o['end_ms'] <= audio['source']['duration_ms']
                       for o in all_occurrences)
    no_overlaps = all(a['end_ms'] <= b['start_ms']
                      for a, b in zip(all_occurrences, all_occurrences[1:]))
    if not bounds_valid or not no_overlaps:
        raise ValueError('Occurrence bounds are invalid or overlap.')
    repeated = [o['repeat_waveform'] for t in task_results for o in t['occurrences']
                if 'repeat_waveform' in o]
    report = {'schema_version': 1, 'source': audio['source'],
              'reference_source': audio['reference_source'],
              'review_status': 'requires_listening_review',
              'human_listening_review_performed': False,
              'summary': {'task_count': len(task_results), 'occurrence_count': len(all_occurrences),
                          'all_official_text_matches': True, 'all_bounds_valid': bounds_valid,
                          'no_overlaps': no_overlaps, 'word_count': word_count,
                          'untimed_word_count': untimed_count,
                          'untimed_percentage': round(100*untimed_count/word_count, 3),
                          'repeated_passages_checked': len(repeated),
                          'repeated_passages_waveform_passed': sum(r['status']=='passed' for r in repeated)},
              'tasks': task_results,
              'method': {'repeat_probes_per_passage': 2, 'probe_duration_ms': 8000,
                         'minimum_waveform_correlation': .98, 'maximum_repeat_offset_drift_ms': 25,
                         'search_normalization': 'ASR anchors only: lowercase and diacritic folding; official text retained.'}}
    report_path = evidence / 'verification.json'
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    audio['report']['verification_path'] = 'alignment/verification.json'
    audio['report']['verification_sha256'] = digest(report_path)
    audio['report']['quality_summary'] = report['summary']
    audio_path.write_text(json.dumps(audio, ensure_ascii=False, indent=2)+'\n')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--alignment-directory', type=Path, required=True)
    args = parser.parse_args(argv)
    report = audit(args.alignment_directory)
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
