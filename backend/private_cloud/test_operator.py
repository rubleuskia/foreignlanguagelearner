import base64
import copy
import json
import os
import time
import unittest
import uuid
from unittest.mock import Mock, patch
import boto3
from moto import mock_aws
from backend.cloud.errors import CloudError
from backend.translation.provider import ProviderFailure
from backend.alignment.repository import MemoryRepository
from backend.alignment.test_service import Storage, Workflow, request
from . import api, alignment
from .auth import authenticate
from .provider import BedrockProvider, MODEL_ID
from .repository import Repository

ENV = {'JWT_ISSUER': 'https://issuer.example', 'JWT_CLIENT_ID': 'client',
       'OPERATOR_USERNAME': 'operator', 'OPERATOR_TABLE': 'requests', 'DAILY_MODEL_LIMIT': '2'}
PAYLOAD = {'schema_version': 1, 'selected_text': 'dom', 'context': 'To jest dom.',
           'selection_location_utf16': 8, 'selection_length_utf16': 3,
           'source_language': 'pl', 'target_language': 'ru', 'words_to_explain': ['dom']}
RESULT = {'phrase_translation': 'дом', 'word_explanations': [{'source_word': 'dom', 'lemma': 'dom', 'meaning': 'дом'}]}


def event(route='POST /v1/context-analyses', key=None):
    return {'routeKey': route, 'headers': {'Authorization': 'Bearer token', 'Idempotency-Key': key or str(uuid.uuid4())},
            'requestContext': {'authorizer': {'jwt': {'claims': {'iss': ENV['JWT_ISSUER'],
                'client_id': 'client', 'token_use': 'access', 'sub': 'owner',
                'scope': 'aws.cognito.signin.user.admin'}}}}, 'body': json.dumps(PAYLOAD)}


class OperatorTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, ENV); env.start(); self.addCleanup(env.stop)
        from urllib.parse import urlparse
        endpoint = os.environ.get('DYNAMODB_LOCAL_URL')
        if endpoint:
            assert urlparse(endpoint).hostname in {'localhost', '127.0.0.1'}
        else:
            mocked = mock_aws(); mocked.start(); self.addCleanup(mocked.stop)
        db = boto3.client('dynamodb', region_name='eu-north-1', endpoint_url=endpoint,
                          aws_access_key_id='local', aws_secret_access_key='local')
        table = 'operator' + uuid.uuid4().hex
        db.create_table(TableName=table, KeySchema=[{'AttributeName': 'id', 'KeyType': 'HASH'}],
                        AttributeDefinitions=[{'AttributeName': 'id', 'AttributeType': 'S'}], BillingMode='PAY_PER_REQUEST')
        self.addCleanup(lambda: db.delete_table(TableName=table))
        self.repo = Repository(db, table)
        self.cognito = Mock()
        self.cognito.get_user.return_value = {'Username': 'operator', 'UserAttributes': [{'Name': 'sub', 'Value': 'owner'}]}
        self.cognito.exceptions.NotAuthorizedException = type('NotAuthorizedException', (Exception,), {})
        self.cognito.exceptions.UserNotFoundException = type('UserNotFoundException', (Exception,), {})
        self.provider = Mock(); self.provider.run.return_value = (RESULT, {'input_tokens': 12, 'output_tokens': 20})
        runtime = patch.object(api, 'runtime', return_value=(self.cognito, self.repo, self.provider))
        runtime.start(); self.addCleanup(runtime.stop)

    def test_access_token_live_identity_and_permanent_operator_subject_pin(self):
        self.assertEqual(authenticate(event(), self.cognito, self.repo), 'owner')
        for field, bad in [('iss', 'foreign'), ('client_id', 'foreign'), ('token_use', 'id'), ('scope', '')]:
            e = event(); e['requestContext']['authorizer']['jwt']['claims'][field] = bad
            with self.subTest(field=field), self.assertRaises(CloudError): authenticate(e, self.cognito, self.repo)
        self.cognito.get_user.return_value['Username'] = 'someone-else'
        with self.assertRaises(CloudError): authenticate(event(), self.cognito, self.repo)
        self.cognito.get_user.return_value['Username'] = 'operator'
        self.cognito.get_user.return_value['UserAttributes'][0]['Value'] = 'new-subject'
        e = event(); e['requestContext']['authorizer']['jwt']['claims']['sub'] = 'new-subject'
        with self.assertRaisesRegex(CloudError, 'OPERATOR_SUBJECT_CHANGED'): authenticate(e, self.cognito, self.repo)

    def test_revoked_token_and_forged_subject_never_reach_provider(self):
        self.cognito.get_user.side_effect = self.cognito.exceptions.NotAuthorizedException()
        self.assertEqual(api.handler(event(), None)['statusCode'], 401)
        self.provider.run.assert_not_called()

    def test_same_key_replays_durable_result_and_changed_input_conflicts(self):
        e = event()
        first = api.handler(e, None); again = api.handler(e, None)
        self.assertEqual(first, again); self.assertEqual(first['statusCode'], 200)
        self.provider.run.assert_called_once()
        value = json.loads(first['body'])
        get = event('GET /v1/requests/{id}'); get['pathParameters'] = {'id': value['request_id']}
        self.assertEqual(json.loads(api.handler(get, None)['body'])['result'], RESULT)
        changed = copy.deepcopy(e); payload = copy.deepcopy(PAYLOAD); payload['words_to_explain'] = []
        changed['body'] = json.dumps(payload)
        self.assertEqual(api.handler(changed, None)['statusCode'], 409)

    def test_timeout_and_failed_output_are_not_automatically_resubmitted(self):
        for unknown in (True, False):
            e = event(); self.provider.run.side_effect = ProviderFailure(unknown=unknown)
            value = json.loads(api.handler(e, None)['body'])
            self.assertEqual(value['state'], 'outcome_unknown' if unknown else 'failed')
            calls = self.provider.run.call_count
            self.assertEqual(json.loads(api.handler(e, None)['body']), value)
            self.assertEqual(self.provider.run.call_count, calls)

    def test_daily_cap_is_atomic_and_replay_does_not_consume_another_slot(self):
        e = event(); api.handler(e, None); api.handler(e, None); api.handler(event(), None)
        self.assertEqual(api.handler(event(), None)['statusCode'], 429)
        self.assertEqual(self.provider.run.call_count, 2)

    def test_lost_response_recovers_unknown_without_new_submission(self):
        now = int(time.time()); key = str(uuid.uuid4())
        row, _ = self.repo.admit('owner', key, 'fingerprint', now - 31, 2)
        self.assertEqual(self.repo.public(row, now)['state'], 'outcome_unknown')
        repeated, fresh = self.repo.admit('owner', key, 'fingerprint', now, 2)
        self.assertFalse(fresh)
        with self.assertRaisesRegex(CloudError, 'RESULT_EXPIRED'):
            self.repo.public(repeated, now + 86400)

    @unittest.skipUnless(os.environ.get('DYNAMODB_LOCAL_URL'), 'Concurrency requires real local DynamoDB')
    def test_concurrent_replay_creates_one_submission_and_consumes_one_admission(self):
        from concurrent.futures import ThreadPoolExecutor
        key = str(uuid.uuid4()); now = int(time.time())
        def submit(_):
            try:
                return self.repo.admit('owner', key, 'fingerprint', now, 2)[1]
            except CloudError as error:
                self.assertEqual(error.code, 'ADMISSION_UNAVAILABLE')
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            fresh = list(pool.map(submit, range(16)))
        self.assertEqual(sum(fresh), 1)
        self.assertEqual(self.repo.get('day:' + str(now // 86400))['admissions'], 1)

    def test_invalid_input_and_short_remaining_deadline_do_not_admit(self):
        e = event(); e['body'] = '{}'
        self.assertEqual(api.handler(e, None)['statusCode'], 400)
        context = Mock(); context.get_remaining_time_in_millis.return_value = 10000
        self.assertEqual(api.handler(event(), context)['statusCode'], 503)
        self.provider.run.assert_not_called()

    def test_alignment_access_survives_token_refresh_but_rejects_other_subject(self):
        repo = MemoryRepository(); service = alignment.OperatorAlignmentService(repo, Storage(), Workflow(),
            bucket='bucket', state_machine_arn='state', accept_new_jobs=True, owner='owner')
        token = 'Bearer ' + base64.urlsafe_b64encode(b'a' * 32).decode().rstrip('=')
        _, job = service.create(request(), token, str(uuid.uuid4()))
        self.assertEqual(service.status(job['job_id'], token)['job_id'], job['job_id'])
        service.owner = 'other'
        from backend.alignment.errors import NotFound
        with self.assertRaises(NotFound): service.status(job['job_id'], token)

    def test_alignment_wrapper_checks_jwt_before_work_and_handles_base64(self):
        e = event(); e['requestContext']['authorizer'] = {}
        with patch.object(alignment, 'runtime', return_value=(self.cognito, self.repo, self.provider)), \
             patch.object(alignment.alignment_api, 'build_service') as build:
            self.assertEqual(alignment.handler(e, None)['statusCode'], 401)
            build.assert_not_called()

    def test_alignment_wrapper_creates_and_reads_job_after_access_token_refresh(self):
        from backend.alignment.service import AlignmentService
        service = AlignmentService(MemoryRepository(), Storage(), Workflow(), bucket='bucket',
                                   state_machine_arn='state', accept_new_jobs=True)
        e = event(); e['pathParameters'] = None
        e['requestContext']['http'] = {'method': 'POST', 'path': '/v1/alignments'}
        e['isBase64Encoded'] = True; e['body'] = base64.b64encode(json.dumps(request()).encode()).decode()
        original = copy.deepcopy(e)
        with patch.object(alignment, 'runtime', return_value=(self.cognito, self.repo, self.provider)), \
             patch.object(alignment.alignment_api, 'build_service', return_value=service):
            created = alignment.handler(e, None)
            self.assertEqual(created['statusCode'], 201, created)
            job_id = json.loads(created['body'])['job_id']
            refreshed = event('GET /v1/alignments/{id}')
            refreshed['headers']['Authorization'] = 'Bearer refreshed-token'
            refreshed['requestContext']['http'] = {'method': 'GET', 'path': '/v1/alignments/' + job_id}
            refreshed['pathParameters'] = {'id': job_id}
            result = alignment.handler(refreshed, None)
            self.assertEqual(result['statusCode'], 200, result)
            self.assertEqual(json.loads(result['body'])['job_id'], job_id)
            self.assertEqual(e, original)


class ProviderTests(unittest.TestCase):
    def test_one_bounded_converse_call_validated_result_and_token_usage(self):
        client = Mock(); client.converse.return_value = {'stopReason': 'end_turn',
            'output': {'message': {'content': [{'text': json.dumps(RESULT)}]}},
            'usage': {'inputTokens': 12, 'outputTokens': 34}}
        result, tokens = BedrockProvider(client).run('context', PAYLOAD)
        self.assertEqual(result, RESULT); self.assertEqual(tokens['output_tokens'], 34)
        client.converse.assert_called_once()
        self.assertEqual(client.converse.call_args.kwargs['modelId'], MODEL_ID)
        self.assertEqual(client.converse.call_args.kwargs['inferenceConfig']['maxTokens'], 2048)

    def test_malformed_schema_or_incomplete_output_is_rejected_without_retry(self):
        for reason, text in [('max_tokens', '{}'), ('end_turn', '{}'), ('end_turn', '```json\n{}\n```')]:
            client = Mock(); client.converse.return_value = {'stopReason': reason,
                'output': {'message': {'content': [{'text': text}]}}}
            with self.assertRaises(ProviderFailure): BedrockProvider(client).run('context', PAYLOAD)
            client.converse.assert_called_once()
