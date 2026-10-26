import hashlib
import json
import unittest

import word_timings


class WordTimingTests(unittest.TestCase):
    def report(self, text=' noga', start=2, end=3):
        return {'track_id': '008', 'alignment': {'segments': [{'words': [
            {'word': ' owrzodzona', 'start': 1, 'end': 2},
            {'word': text, 'start': start, 'end': end}]}]}}

    def make(self, report):
        return word_timings.make_file(report, '1\n00:00:00,000 --> 00:00:05,000\nowrzodzona\nnoga\n', '008', 'a' * 64, 5)

    def test_keeps_word_boundaries_and_zero_duration(self):
        data = json.loads(self.make(self.report()))
        self.assertEqual(data['textSHA256'], hashlib.sha256('owrzodzona noga'.encode()).hexdigest())
        self.assertEqual(data['words'][1], {'text': 'noga', 'start': 2, 'end': 3})
        self.assertEqual(json.loads(self.make(self.report(end=2)))['words'][1]['end'], 2)

    def test_rejects_wrong_text_track_audio_and_invalid_times(self):
        for report in [self.report(text=' nogi'), self.report(start=-1), self.report(end=7), self.report(start=1.5)]:
            with self.assertRaises(ValueError):
                self.make(report)
        report = self.report()
        report['track_id'] = '009'
        with self.assertRaises(ValueError):
            self.make(report)
        report = self.report()
        report['fingerprint'] = {'audio_sha256': 'b' * 64}
        with self.assertRaises(ValueError):
            self.make(report)

    def test_applies_input_offset_once(self):
        report = self.report()
        report['offset_seconds'] = 1
        self.assertEqual(json.loads(self.make(report))['words'][0]['start'], 2)
