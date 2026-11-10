"""Cloud harness failures must retain evidence without accepting quality or leaking text."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
from unittest.mock import Mock


class BenchmarkHarnessTests(unittest.TestCase):
    def test_active_task_blocks_fixture_overwrite(self):
        spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('alignment-benchmark-aws.py'))
        benchmark = importlib.util.module_from_spec(spec); spec.loader.exec_module(benchmark)
        clients = {name: Mock() for name in ['sts', 'cloudformation', 'ecs', 's3']}
        clients['sts'].get_caller_identity.return_value = {'Account': '123456789012'}
        clients['cloudformation'].describe_stacks.return_value = {'Stacks': [{
            'Tags': [{'Key': 'Purpose', 'Value': 'fll-audio-benchmark'}],
            'Outputs': [{'OutputKey': 'Cluster', 'OutputValue': 'arn:aws:ecs:eu-north-1:123456789012:cluster/benchmark'}]}]}
        clients['ecs'].get_paginator.return_value.paginate.return_value = [{'taskArns': ['active']}]
        session = Mock(); session.client.side_effect = lambda name, **_: clients[name]
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp)/'audio.wav'; fixture.write_bytes(b'audio')
            argv = ['benchmark', '--project', '123456789012', '--audio', str(fixture),
                    '--text', str(fixture), '--output', str(Path(temp)/'out')]
            with patch('sys.argv', argv), patch.object(benchmark.boto3, 'Session', return_value=session):
                with self.assertRaisesRegex(ValueError, 'active'):
                    benchmark.main()
        clients['s3'].upload_file.assert_not_called()
        clients['ecs'].run_task.assert_not_called()

    def test_cleanup_refuses_evidence_for_another_bucket(self):
        spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).with_name('cleanup-alignment-benchmark.py'))
        cleanup = importlib.util.module_from_spec(spec); spec.loader.exec_module(cleanup)
        clients = {name: Mock() for name in ['sts', 'cloudformation', 'ecs', 's3']}
        clients['sts'].get_caller_identity.return_value = {'Account': '123456789012'}
        clients['cloudformation'].describe_stacks.return_value = {'Stacks': [{
            'StackId': 'benchmark-stack', 'Tags': [{'Key': 'Purpose', 'Value': 'fll-audio-benchmark'}],
            'Outputs': [{'OutputKey': 'Bucket', 'OutputValue': 'another-bucket'}]}]}
        session = Mock(); session.client.side_effect = lambda name, **_: clients[name]
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp)/'aws-measurements.json').write_text(json.dumps({
                'project': '123456789012', 'stackId': 'benchmark-stack', 'bucket': 'recorded-bucket'}))
            with patch('sys.argv', ['cleanup', '--project', '123456789012', '--evidence', temp]), \
                 patch.object(cleanup.boto3, 'Session', return_value=session):
                with self.assertRaisesRegex(ValueError, 'not the disposable benchmark'):
                    cleanup.main()
        clients['s3'].delete_objects.assert_not_called()
        clients['cloudformation'].delete_stack.assert_not_called()

    def test_engine_failure_preserves_private_logs_and_cannot_accept_quality(self):
        spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('alignment-benchmark-aws.py'))
        benchmark = importlib.util.module_from_spec(spec); spec.loader.exec_module(benchmark)
        uploaded = {}
        fixtures = {'audio.wav': b'audio fixture', 'transcript.txt': b'matching transcript'}
        class S3:
            def download_file(self, bucket, key, target):
                Path(target).write_bytes(fixtures[Path(key).name])
            def upload_file(self, path, bucket, key):
                uploaded[key] = Path(path).read_bytes()
        def fail(_):
            print('private transcript sentinel')
            raise ValueError('engine failed')
        engine = types.ModuleType('align')
        arguments = []
        engine.parser = lambda: types.SimpleNamespace(parse_args=lambda values: arguments.append(values))
        engine.run = fail
        worker = types.ModuleType('worker.worker'); worker.probe_duration = lambda _: 300
        with tempfile.TemporaryDirectory() as temp:
            driver = benchmark.cloud_driver().replace('/tmp/result', temp+'/result').replace('/tmp/fixture', temp+'/fixture')
            env = {'BENCHMARK_BUCKET': 'test-bucket', 'BENCHMARK_RUN_ID': 'test-run',
                   'BENCHMARK_ALLOW_UNTIMED_WORDS': 'true',
                   **{'BENCHMARK_'+name+'_SHA256': hashlib.sha256(fixtures[key]).hexdigest()
                      for name, key in [('AUDIO','audio.wav'),('TEXT','transcript.txt')]}}
            stdout = io.StringIO()
            import contextlib
            with patch.dict(os.environ, env), patch.dict('sys.modules', {'align': engine, 'worker.worker': worker}), \
                 patch('boto3.client', return_value=S3()), contextlib.redirect_stdout(stdout):
                with self.assertRaises(SystemExit) as error:
                    exec(driver, {})
            self.assertEqual(error.exception.code, 1)
        row = json.loads(uploaded['results/test-run/measurement.json'])
        self.assertFalse(row['success']); self.assertFalse(row['qualityAccepted'])
        self.assertTrue(row['allowUntimedWords'])
        self.assertIn('--allow-untimed-words', arguments[0])
        self.assertIsNone(row['costUsd'])
        self.assertIn(b'private transcript sentinel', uploaded['results/test-run/private.log'])
        self.assertNotIn('private transcript sentinel', stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
