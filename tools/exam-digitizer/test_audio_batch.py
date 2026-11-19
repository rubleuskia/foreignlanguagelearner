import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('audio_batch', HERE / 'audio_batch.py')
batch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(batch)


class FakeEngine:
    metadata = {'producer': 'test engine', 'torch_version': 'none', 'device': 'cpu'}
    created = 0
    calls = []
    mutate = None

    def __init__(self, model, threads):
        type(self).created += 1

    def transcribe(self, path, language):
        type(self).calls.append(path.name)
        if type(self).mutate: type(self).mutate(path)
        return {'language': language, 'segments': [{'start': 0, 'end': 1,
            'text': ' Żółty kot słucha. ', 'words': [{'word': 'kot', 'start': 0.2, 'end': 0.4}]}]}


class AudioBatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources, self.output = self.root / 'sources', self.root / 'batch'
        self.sources.mkdir(); self.output.mkdir()
        self.jobs = []
        for number in (1, 2):
            path = self.sources / f'audio-{number}.mp3'
            path.write_bytes(f'original recording {number}'.encode())
            source = {'path': path.name, 'url': f'https://example.test/{path.name}',
                      'bytes': path.stat().st_size, 'sha256': batch.digest(path)}
            self.jobs.append({'id': f'2024/session/B{number}', 'directory': f'2024/session/B{number}',
                'selection': {'year': '2024'}, 'sources': {'audio': source}, 'existing_package': None})
        self.write_index()
        FakeEngine.created = 0; FakeEngine.calls = []; FakeEngine.mutate = None

    def write_index(self):
        batch.atomic_json(self.output / 'batch-index.json', {'schema_version': '1.0',
            'sources_root': str(self.sources), 'jobs': self.jobs})

    def run_batch(self, **kwargs):
        runner = batch.Batch(self.output, self.sources, engine_factory=FakeEngine, probe=lambda _: 5, **kwargs)
        code = runner.execute()
        return runner, code

    def artifacts(self, number=0):
        return self.output / self.jobs[number]['directory'] / 'audio' / 'asr'

    def test_one_model_serves_all_jobs_with_source_bound_atomic_artifacts(self):
        runner, code = self.run_batch()
        self.assertEqual(code, 0)
        self.assertEqual(FakeEngine.created, 1)
        self.assertEqual(FakeEngine.calls, ['audio-1.mp3', 'audio-2.mp3'])
        self.assertEqual(runner.run['completed'], 2)
        for index, job in enumerate(self.jobs):
            quality = batch.validate_cache(self.artifacts(index), job['sources']['audio'], runner.settings)
            self.assertFalse(quality['forced_alignment_executed'])
            self.assertFalse(quality['task_occurrences_verified'])
            self.assertFalse(quality['human_review_performed'])
            self.assertIn('Żółty', (self.artifacts(index) / 'rough-transcription.txt').read_text())
            self.assertTrue((self.artifacts(index) / 'rough-transcription.srt').is_file())
            self.assertFalse(list(self.artifacts(index).parent.glob('.stage-*')))

    def test_resume_checks_hashes_without_loading_or_rerunning_model(self):
        self.run_batch()
        FakeEngine.created = 0; FakeEngine.calls = []
        runner, code = self.run_batch()
        self.assertEqual(code, 0)
        self.assertEqual(runner.run['cached'], 2)
        self.assertEqual(FakeEngine.created, 0)
        self.assertEqual(FakeEngine.calls, [])

    def test_corrupt_cached_artifact_is_retained_and_can_be_explicitly_quarantined(self):
        self.run_batch()
        file = self.artifacts() / 'rough-transcription.txt'
        file.write_text('User changed this artifact.')
        runner, code = self.run_batch()
        self.assertEqual(code, 1)
        self.assertEqual(runner.run['failed'], 1)
        self.assertEqual(runner.run['cached'], 1)
        self.assertEqual(file.read_text(), 'User changed this artifact.')
        runner, code = self.run_batch(retry_invalid=True)
        self.assertEqual(code, 0)
        rejected = list(file.parent.parent.glob('rejected-asr-*'))
        self.assertEqual(len(rejected), 1)
        self.assertEqual((rejected[0] / file.name).read_text(), 'User changed this artifact.')

    def test_original_change_during_recognition_fails_before_publication_and_other_job_continues(self):
        def mutate(path):
            if path.name == 'audio-1.mp3': path.write_bytes(b'changed during recognition')
        FakeEngine.mutate = mutate
        runner, code = self.run_batch()
        self.assertEqual(code, 1)
        self.assertEqual(runner.run['failed'], 1)
        self.assertEqual(runner.run['completed'], 1)
        self.assertFalse(self.artifacts().exists())
        self.assertTrue(self.artifacts(1).exists())
        status = json.loads((self.artifacts().parent / 'status.json').read_text())
        self.assertIn('differs from the download manifest', status['error'])

    def test_original_corruption_is_detected_even_when_cache_is_complete(self):
        self.run_batch()
        (self.sources / 'audio-1.mp3').write_bytes(b'changed')
        FakeEngine.calls = []
        runner, code = self.run_batch()
        self.assertEqual(code, 1)
        self.assertEqual(runner.run['failed'], 1)
        self.assertEqual(runner.run['cached'], 1)
        self.assertEqual(FakeEngine.calls, [])

    def test_bounds_issues_are_preserved_for_review_without_fabricated_subtitle_times(self):
        original = FakeEngine.transcribe
        def transcribe(engine, path, language):
            result = original(engine, path, language)
            result['segments'][0]['end'] = 9
            return result
        from unittest.mock import patch
        with patch.object(FakeEngine, 'transcribe', transcribe):
            runner, code = self.run_batch()
        self.assertEqual(code, 0)
        quality = json.loads((self.artifacts() / 'quality-report.json').read_text())
        self.assertEqual(quality['timestamp_review_issues'][0]['end'], 9)
        self.assertFalse((self.artifacts() / 'rough-transcription.srt').exists())
        result = json.loads((self.artifacts() / 'rough-transcription.json').read_text())
        self.assertEqual(result['segments'][0]['end'], 9)

    def test_model_or_unlisted_cache_files_are_not_silently_reused(self):
        self.run_batch()
        runner, code = self.run_batch(model='tiny')
        self.assertEqual(code, 1)
        self.assertEqual(runner.run['failed'], 2)
        (self.artifacts() / 'unlisted.txt').write_text('untracked')
        with self.assertRaisesRegex(ValueError, 'unlisted'):
            batch.validate_cache(self.artifacts(), self.jobs[0]['sources']['audio'], runner.settings | {'model': 'base'})

    def test_lock_prevents_concurrent_batches_and_releases_on_exit(self):
        with batch.run_lock(self.output):
            with self.assertRaisesRegex(ValueError, 'Another audio batch'):
                with batch.run_lock(self.output): pass
        with batch.run_lock(self.output): pass

    def test_path_traversal_and_audio_symlink_escape_are_rejected(self):
        self.jobs[0]['directory'] = '../escape'
        self.write_index()
        with self.assertRaisesRegex(ValueError, 'escapes'):
            batch.load_jobs(self.output, self.sources)
        self.jobs[0]['directory'] = '2024/session/B1'
        self.write_index()
        folder = self.output / self.jobs[0]['directory']
        folder.mkdir(parents=True)
        (folder / 'audio').symlink_to(self.sources, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            batch.load_jobs(self.output, self.sources)

    def test_reviewed_pilot_skip_is_bound_to_actual_original_hash(self):
        package = self.root / 'pilot'; package.mkdir()
        (package / 'exam.json').write_text(json.dumps({'id': 'pilot', 'revision': 'revision',
            'sources': [{'id': 'audio', 'sha256': self.jobs[0]['sources']['audio']['sha256']}]}))
        self.jobs[0]['existing_package'] = str(package)
        self.write_index()
        runner, code = self.run_batch()
        self.assertEqual(code, 0)
        self.assertEqual(runner.run['existing_reviewed'], 1)
        self.assertEqual(FakeEngine.calls, ['audio-2.mp3'])


if __name__ == '__main__': unittest.main()
