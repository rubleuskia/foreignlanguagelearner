import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('audio_verify', Path(__file__).with_name('audio_verify.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class RepeatedWaveformTests(unittest.TestCase):
    def test_shorter_repeat_uses_common_duration(self):
        primary = [0] * (40*8000)
        def probe(left, right, position):
            self.assertLessEqual(position + 8, min(len(left), len(right)) / 8000)
            return {'correlation': 1, 'primary_local_start_ms': round(position*1000),
                    'repeat_local_start_ms': round(position*1000)}
        with patch.object(verify, 'waveform_probe', side_effect=probe):
            result = verify.compare_repeated(primary, primary[:30*8000])
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(len(result['probes']), 2)

    def test_short_or_unrelated_audio_never_claims_verified_repeat(self):
        primary = [0] * (30*8000)
        self.assertEqual(verify.compare_repeated(primary, primary[:10*8000])['status'], 'requires_review')
        with patch.object(verify, 'waveform_probe', return_value={
                'correlation': .1, 'primary_local_start_ms': 0, 'repeat_local_start_ms': 0}):
            self.assertEqual(verify.compare_repeated(primary, primary)['status'], 'requires_review')
