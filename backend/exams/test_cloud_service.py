"""Real SDK request shapes against local AWS models; no network credentials needed."""
import copy
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import uuid

try:
    import boto3
    from moto import mock_aws
except ImportError:
    boto3 = None

from .cloud_assets import CloudAssets
from .cloud_cli import main
from .cloud_repository import CloudRepository, ConcurrentWrite, owner_partition
from .cloud_service import CloudService, preview
from .contract import ExamError, fingerprint
from .test_service import fixture, refresh_package


@unittest.skipIf(boto3 is None, 'Cloud integration tests require boto3 and moto[s3,dynamodb].')
class CloudServiceTests(unittest.TestCase):
    def setUp(self):
        self.mock = mock_aws(); self.mock.start()
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.package = self.root / 'package'; self.exam = fixture(self.package)
        self.clock = [1800000000]
        self.table = boto3.resource('dynamodb', region_name='eu-north-1').create_table(
            TableName='exam-test', KeySchema=[{'AttributeName':'pk','KeyType':'HASH'},
                {'AttributeName':'sk','KeyType':'RANGE'}],
            AttributeDefinitions=[{'AttributeName':'pk','AttributeType':'S'},
                {'AttributeName':'sk','AttributeType':'S'}], BillingMode='PAY_PER_REQUEST')
        self.s3 = boto3.client('s3', region_name='eu-north-1')
        self.s3.create_bucket(Bucket='private-exam-test', CreateBucketConfiguration={'LocationConstraint':'eu-north-1'})
        self.s3.put_bucket_versioning(Bucket='private-exam-test', VersioningConfiguration={'Status':'Enabled'})
        self.service = self.restart()

    def tearDown(self):
        self.temp.cleanup(); self.mock.stop()

    def restart(self):
        return CloudService(CloudRepository(self.table), CloudAssets(self.s3, 'private-exam-test'),
                            now=lambda:self.clock[0])

    def publish(self, folder=None, transaction=None):
        folder = folder or self.package
        result = self.service.publish('operator', folder, transaction or str(uuid.uuid4()), preview(folder)['manifest_digest'])
        self.service.set_active(result['exam_id'], True)
        return result

    def test_inactive_exams_are_hidden_and_cannot_be_opened_or_started(self):
        self.publish()
        attempt = self.attempt()
        self.service.set_active(self.exam['id'], False)
        self.assertEqual(self.restart().catalog()['exams'], [])
        self.error('EXAM_NOT_FOUND', lambda:self.service.student_package(self.exam['id']))
        self.error('EXAM_NOT_FOUND', lambda:self.service.student_package(self.exam['id'], self.exam['revision']))
        self.error('EXAM_NOT_FOUND', lambda:self.service.download_metadata(self.exam['id'], self.exam['revision'], 'audio'))
        self.error('EXAM_NOT_FOUND', lambda:self.attempt())
        self.assertEqual(self.service.get_attempt('alice', attempt['id'])['id'], attempt['id'])
        self.assertEqual(self.service.list_attempts('alice')['attempts'][0]['id'], attempt['id'])
        self.service.set_active(self.exam['id'], True)
        self.assertEqual(self.restart().catalog()['exams'][0]['id'], self.exam['id'])
        self.assertEqual(self.service.student_package(self.exam['id'])['exam']['revision'], self.exam['revision'])

    def test_new_publications_are_inactive_and_revisions_preserve_visibility(self):
        self.service.publish('operator', self.package, str(uuid.uuid4()), preview(self.package)['manifest_digest'])
        self.assertEqual(self.service.catalog()['exams'], [])

        pointer = self.service.repository.get('CATALOG', 'EXAM#' + self.exam['id'])
        self.assertIs(pointer['active'], False)
        newer = self.root / 'inactive-newer'; shutil.copytree(self.package, newer)
        refresh_package(newer, 'Still hidden')
        self.service.publish('operator', newer, str(uuid.uuid4()), preview(newer)['manifest_digest'])
        self.assertEqual(self.service.catalog()['exams'], [])
        self.service.set_active(self.exam['id'], True)
        latest = self.root / 'active-newer'; shutil.copytree(newer, latest)
        refresh_package(latest, 'Still active')
        self.service.publish('operator', latest, str(uuid.uuid4()), preview(latest)['manifest_digest'])
        self.assertEqual(self.service.catalog()['exams'][0]['title'], 'Still active')
        self.table.update_item(Key={'pk':'CATALOG','sk':'EXAM#'+self.exam['id']}, UpdateExpression='REMOVE active')
        self.assertEqual(self.service.catalog()['exams'], [])

    def test_publication_retries_when_exam_is_disabled_concurrently(self):
        self.publish()
        newer = self.root / 'concurrent-newer'; shutil.copytree(self.package, newer)
        refresh_package(newer, 'New content stays hidden')
        original = self.service.repository.transaction
        interleaved = []
        def disable_before_commit(rows):
            if not interleaved and any(row['pk'] == 'CATALOG' for row, _ in rows):
                interleaved.append(True)
                self.service.set_active(self.exam['id'], False)
            return original(rows)
        with patch.object(self.service.repository, 'transaction', side_effect=disable_before_commit):
            self.service.publish('operator', newer, str(uuid.uuid4()), preview(newer)['manifest_digest'])
        self.assertEqual(self.service.catalog()['exams'], [])
        self.assertEqual(self.service.repository.get('CATALOG', 'EXAM#' + self.exam['id'])['revision'], preview(newer)['revision'])

    def attempt(self, sections=('reading',), mode='exam', owner='alice'):
        return self.service.create_attempt(owner, {'attempt_id':str(uuid.uuid4()), 'exam_id':self.exam['id'],
            'revision':self.exam['revision'], 'device_id':'a', 'mode':mode, 'section_ids':list(sections)})

    def request(self, attempt, **kwargs):
        return {'base_version':attempt['version'], 'change_id':str(uuid.uuid4()), 'device_id':'a', **kwargs}

    def error(self, code, call):
        with self.assertRaises(ExamError) as raised: call()
        self.assertEqual(raised.exception.code, code)
        return raised.exception

    def test_dry_run_is_read_only_and_cloud_http_imports_are_disabled(self):
        with patch.object(CloudService, 'configured', side_effect=AssertionError('AWS must not be initialized')):
            with patch('sys.stdout', new=io.StringIO()):
                self.assertEqual(main(['dry-run', str(self.package)]), 0)
        self.assertEqual(self.service.catalog()['exams'], [])
        self.assertNotIn('Contents', self.s3.list_objects_v2(Bucket='private-exam-test'))
        self.error('EXAM_CLOUD_IMPORT_REQUIRES_ADMIN_CLI', lambda:self.service.handle(
            'POST /v1/exam-imports/dry-run', 'alice', {'package_dir':str(self.package)}))

    def test_publication_is_durable_idempotent_and_keys_are_never_signed(self):
        tx = str(uuid.uuid4()); result = self.publish(transaction=tx)
        self.service = self.restart()
        self.assertEqual(result, self.publish(transaction=tx))
        public = self.service.student_package(self.exam['id'])
        text = json.dumps(public)
        for private in ['accepted_answers', 'ai_assessment', 'reference_answer', '"keys"', 'private_transcript']:
            self.assertNotIn(private, text)
        for source in public['exam']['sources']:
            self.assertIn('versionId', parse_qs(urlsplit(source['download_url']).query))
            self.assertNotIn('download_path', source)
        self.error('EXAM_SOURCE_NOT_FOUND', lambda:self.service.download_metadata(
            self.exam['id'], self.exam['revision'], 'keys'))
        changed = self.root / 'changed'; shutil.copytree(self.package, changed)
        refresh_package(changed, 'Different revision')
        self.error('IMPORT_TRANSACTION_CONFLICT', lambda:self.publish(changed, tx))

    def test_transport_repack_does_not_downgrade_latest_catalog(self):
        self.publish()
        newer = self.root / 'newer'; shutil.copytree(self.package, newer)
        newest = refresh_package(newer, 'Newer reviewed content'); self.publish(newer)
        repack = self.root / 'repack'; shutil.copytree(self.package, repack)
        (repack/'transport-note.txt').write_text('Repacked transport only.\n'); refresh_package(repack)
        self.assertTrue(self.publish(repack)['content_unchanged'])
        self.assertEqual(self.service.catalog()['exams'][0]['revision'], newest['revision'])

    def test_partial_upload_never_publishes_and_can_resume_without_overwriting(self):
        original = self.service.assets.put_file; calls = []
        def fail(key, *args):
            calls.append(key)
            if len(calls) == 3: raise RuntimeError('Interrupted upload')
            return original(key, *args)
        with patch.object(self.service.assets, 'put_file', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, 'Interrupted'): self.publish()
        self.assertEqual(self.service.catalog()['exams'], [])
        self.publish()
        self.assertEqual(len(self.service.catalog()['exams']), 1)

    def test_asset_versions_remain_pinned_after_external_overwrite(self):
        self.publish()
        row = self.table.get_item(Key={'pk':'EXAM#'+self.exam['id'], 'sk':'REV#'+self.exam['revision']})['Item']
        original = row['public_assets']['audio']
        self.s3.put_object(Bucket='private-exam-test', Key=original['key'], Body=b'Overwritten outside importer')
        descriptor = self.service.download_metadata(self.exam['id'], self.exam['revision'], 'audio')
        self.assertEqual(parse_qs(urlsplit(descriptor['download_url']).query)['versionId'], [original['version_id']])

    def test_owner_scope_change_replay_version_conflict_and_device_takeover(self):
        self.publish(); attempt = self.attempt()
        request = self.request(attempt, responses={'reading-I-1':'reading-I-option-1-b'})
        updated = self.service.update_attempt('alice', attempt['id'], request)
        self.assertEqual(self.restart().update_attempt('alice', attempt['id'], request)['version'], updated['version'])
        self.error('EXAM_ATTEMPT_NOT_FOUND', lambda:self.service.get_attempt('bob', attempt['id']))
        self.assertEqual(self.service.list_attempts('bob')['attempts'], [])
        self.error('EXAM_ATTEMPT_CONFLICT', lambda:self.service.update_attempt('alice', attempt['id'], self.request(attempt)))
        changed = copy.deepcopy(request); changed['responses']['reading-I-1'] = 'reading-I-option-1-a'
        self.error('EXAM_CHANGE_ID_CONFLICT', lambda:self.service.update_attempt('alice', attempt['id'], changed))
        takeover = self.request(updated, device_id='b')
        self.error('EXAM_DEVICE_CONFLICT', lambda:self.service.update_attempt('alice', attempt['id'], takeover))
        takeover['takeover'] = True
        self.assertEqual(self.service.update_attempt('alice', attempt['id'], takeover)['active_device_id'], 'b')

    def test_concurrent_update_cannot_overwrite_winner_or_consume_losing_change_id(self):
        self.publish(); attempt = self.attempt()
        winner = self.request(attempt, responses={'reading-I-1':'reading-I-option-1-b'})
        loser = self.request(attempt, responses={'reading-I-1':'reading-I-option-1-a'})
        original = self.service.repository.transaction; injected = []
        def interleave(rows):
            if not injected:
                injected.append(True)
                self.restart().update_attempt('alice', attempt['id'], winner)
            return original(rows)
        with patch.object(self.service.repository, 'transaction', side_effect=interleave):
            self.error('EXAM_ATTEMPT_CONFLICT', lambda:self.service.update_attempt('alice', attempt['id'], loser))
        current = self.service.get_attempt('alice', attempt['id'])
        self.assertEqual(current['responses']['reading-I-1'], 'reading-I-option-1-b')
        self.assertIsNone(self.service.repository.get(owner_partition('alice'), f"CHANGE#{attempt['id']}#{loser['change_id']}"))

    def test_expired_section_is_saved_before_late_response_is_rejected(self):
        self.publish(); attempt = self.attempt(); self.clock[0] += 3000
        self.error('EXAM_ATTEMPT_CONFLICT', lambda:self.service.update_attempt('alice', attempt['id'],
            self.request(attempt, responses={'reading-I-1':'reading-I-option-1-b'})))
        current = self.restart().get_attempt('alice', attempt['id'])
        self.assertEqual(current['section_submission_reasons'], {'reading':'deadline'})
        self.assertEqual(current['responses'], {})

    def test_verified_assessment_replay_and_revision_checks_use_shared_contract(self):
        self.publish(); attempt = self.attempt(('grammar',), 'training')
        self.service.submit_attempt('alice', attempt['id'], self.request(attempt))
        contract = self.service.assessment_input('alice', attempt['id'], 'grammar-V')['contract']
        provenance = {'provider':'openai','mode':'subscription','model':'gpt-5-mini','reasoning_effort':'minimal',
            'revision':self.exam['revision'],'contract_sha256':contract['contract_sha256']}
        result = {'score_units':25,'rationale':'Synthetic partial result.'}
        self.error('UNVERIFIED_SERVER_ASSESSMENT', lambda:self.service.record_assessment(
            'alice', attempt['id'], 'grammar-V', result, provenance))
        saved = self.service.record_assessment('alice', attempt['id'], 'grammar-V', result, provenance, server_verified=True)
        replay = self.restart().record_assessment('alice', attempt['id'], 'grammar-V', result, provenance, server_verified=True)
        self.assertEqual(saved['version'], replay['version'])
        self.assertEqual(saved['assessments']['grammar-V']['origin'], 'server_provider')

    def test_item_limit_fails_before_aws_write(self):
        with patch.object(self.table, 'put_item', side_effect=AssertionError('No request for oversized item')):
            self.error('EXAM_RECORD_TOO_LARGE', lambda:self.service.repository.new(
                {'pk':'test','sk':'test','text':'ą' * 200000}))

    def test_real_sdk_serializes_query_and_nested_transaction_conditions(self):
        captured = {}
        def capture(model, params, **kwargs):
            captured.setdefault(model.name, []).append(json.loads(params['body']))
        self.table.meta.client.meta.events.register('before-call.dynamodb.Query', capture)
        self.table.meta.client.meta.events.register('before-call.dynamodb.TransactWriteItems', capture)
        self.publish()
        self.service.catalog()
        attempt = self.attempt()
        self.service.update_attempt('alice', attempt['id'], self.request(attempt))
        transaction = captured['TransactWriteItems'][0]['TransactItems']
        for operation in transaction:
            put = operation['Put']
            self.assertIsInstance(put['ConditionExpression'], str)
            self.assertIsInstance(put['ExpressionAttributeNames'], dict)
            self.assertIn('S', put['Item']['pk'])
        query = captured['Query'][0]
        self.assertIsInstance(query['KeyConditionExpression'], str)
        self.assertIn({'S':'CATALOG'}, query['ExpressionAttributeValues'].values())
        cas = captured['TransactWriteItems'][-1]['TransactItems'][0]['Put']
        self.assertIn({'N':'1'}, cas['ExpressionAttributeValues'].values())
        self.assertIn({'S':'alice'}, cas['ExpressionAttributeValues'].values())
        self.assertEqual(cas['Item']['version'], {'N':'2'})

    def test_query_paginator_reads_all_pages_without_scan(self):
        captured = []
        self.table.meta.client.meta.events.register('before-call.dynamodb.Query',
            lambda **kwargs: captured.append(True))
        for n in range(5):
            self.table.put_item(Item={'pk':'page-test','sk':f'entry#{n}','payload':'x'*300000})
        rows = list(self.service.repository.query('page-test', 'entry#'))
        self.assertEqual(len(rows), 5)
        self.assertGreater(len(captured), 1)

    def test_runtime_requires_complete_cloud_configuration_and_never_falls_back(self):
        from . import runtime
        marker = object()
        with patch.object(runtime, '_instance', None), patch.dict(os.environ,
                {'EXAMS_TABLE':'exam-test','EXAMS_BUCKET':'private-exam-test','AWS_REGION':'eu-north-1'}, clear=True):
            with patch.object(CloudService, 'configured', return_value=marker) as configured:
                self.assertIs(runtime.service(), marker)
                self.assertIs(runtime.service(), marker)
                configured.assert_called_once_with('exam-test', 'private-exam-test', region='eu-north-1')
        for values in [{'EXAMS_TABLE':'t'}, {'EXAMS_BUCKET':'b'},
                       {'EXAMS_TABLE':'t','EXAMS_BUCKET':'b','EXAM_STORAGE_ROOT':'/tmp/local'}]:
            with patch.object(runtime, '_instance', None), patch.dict(os.environ, values, clear=True):
                with self.assertRaises(Exception) as raised: runtime.service()
                self.assertEqual(raised.exception.code, 'EXAMS_CONFIGURATION_CONFLICT')

    def test_cli_commit_report_replays_and_rejects_another_transaction(self):
        tx = str(uuid.uuid4()); report = self.root / 'receipts' / 'import.json'
        args = ['--table','exam-test','--bucket','private-exam-test','commit',str(self.package),
                '--transaction-id',tx,'--manifest-digest',preview(self.package)['manifest_digest'],
                '--report',str(report)]
        with patch.object(CloudService, 'configured', return_value=self.service), patch('sys.stdout', new=io.StringIO()):
            self.assertEqual(main(args), 0)
            original = report.read_bytes()
            self.assertEqual(main(args), 0)
            self.assertEqual(report.read_bytes(), original)
            changed = args.copy(); changed[changed.index('--transaction-id') + 1] = str(uuid.uuid4())
            self.assertEqual(main(changed), 1)
            self.assertEqual(report.read_bytes(), original)

    def test_cli_digest_conflict_does_not_initialize_aws(self):
        args = ['--table','t','--bucket','b','commit',str(self.package), '--transaction-id',str(uuid.uuid4()),
                '--manifest-digest','a'*64,'--report',str(self.root/'receipt.json')]
        with patch.object(CloudService, 'configured', side_effect=AssertionError('No AWS call')):
            with patch('sys.stdout', new=io.StringIO()): self.assertEqual(main(args), 1)


if __name__ == '__main__':
    unittest.main()
