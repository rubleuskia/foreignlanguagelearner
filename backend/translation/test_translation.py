import copy
import datetime
import io
import json
import os
from urllib.parse import urlparse
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from unittest.mock import Mock, patch
from uuid import uuid4
import boto3
from moto import mock_aws
from backend.billing.repository import DynamoRepository as BillingRepository
from backend.billing.domain import Subscription
from backend.cloud.errors import CloudError
from backend.translation.repository import Repository
from backend.translation.service import TranslationService
from backend.translation.policy import Policy, period
from backend.translation.contract import validate_input, validate_output, units
from backend.translation.provider import OpenAIProvider, ProviderFailure


def payload(selected='cat cat', context=None, language='en'):
    return {'schema_version': 1, 'selected_text': selected, 'context': context or selected,
        'selection_location_utf16': 0, 'selection_length_utf16': units(selected),
        'source_language': language, 'target_language': 'ru', 'words_to_explain': selected.split()}


def result(value):
    return {'phrase_translation': 'Перевод', 'word_explanations': [
        {'source_word': w, 'lemma': w.lower(), 'meaning': 'значение'} for w in value['words_to_explain']]}


def policy(**changes):
    return Policy.load(json.dumps({'version': 'cloud-v1', 'products': {'monthly': {'translations': 3, 'alignments': 2}},
        'daily_limit': 100, 'concurrent_limit': 10, 'per_user_concurrent': 5, 'per_user_minute': 100,
        'model': 'gpt-5-mini', 'output_tokens': 2048, **changes}), True, True)


class TranslationTests(unittest.TestCase):
    def setUp(self):
        endpoint = None if getattr(self, 'force_moto', False) else (os.environ.get('DYNAMODB_LOCAL_URL') or None)
        if endpoint:
            assert urlparse(endpoint).hostname in {'localhost', '127.0.0.1'}
        else:
            self.aws = mock_aws(); self.aws.start(); self.addCleanup(self.aws.stop)
        self.client = boto3.client('dynamodb', region_name='eu-central-1', endpoint_url=endpoint,
            aws_access_key_id='local', aws_secret_access_key='local')
        prefix = 'test' + uuid4().hex
        names = {n: prefix+n for n in ['accounts', 'subscriptions', 'events', 'requests', 'contents', 'usage']}
        self.addCleanup(lambda: [self.client.delete_table(TableName=n) for n in names.values()])
        for name, key in [('accounts', 'user_id'), ('subscriptions', 'chain_key'), ('events', 'event_id'),
                          ('requests', 'request_id'), ('contents', 'request_id'), ('usage', 'counter_id')]:
            attributes=[{'AttributeName':key,'AttributeType':'S'}]; extra={}
            if name=='accounts':
                attributes.append({'AttributeName':'apple_subject','AttributeType':'S'})
                extra={'GlobalSecondaryIndexes':[{'IndexName':'AppleSubject','KeySchema':[{'AttributeName':'apple_subject','KeyType':'HASH'}],'Projection':{'ProjectionType':'KEYS_ONLY'}}]}
            self.client.create_table(TableName=names[name],KeySchema=[{'AttributeName':key,'KeyType':'HASH'}],
                AttributeDefinitions=attributes,BillingMode='PAY_PER_REQUEST',**extra)
        self.billing = BillingRepository(self.client, names['accounts'], names['subscriptions'], names['events'], 'Sandbox')
        self.account = self.billing.account('alice')
        self.now = 1793491200
        self.subscription = Subscription('chain', 'tx', 'monthly', self.account['app_account_token'], 'subscribed', self.now + 10000000, self.now)
        self.billing.save_subscription(self.account, self.subscription, None)
        self.repo = Repository(self.client, names['requests'], names['contents'], names['usage'], names['accounts'], names['subscriptions'])
        self.provider = Mock()
        self.provider.run.side_effect = lambda kind, value, *_: (result(value), {'input_tokens': 20, 'output_tokens': 30})
        self.service = TranslationService(self.repo, self.billing, policy(), self.provider, clock=lambda: self.now)

    def submit(self, value=None, key=None):
        return self.service.submit('alice', 'context', value or payload(), key or str(uuid4()))

    def test_requested_model_and_reasoning_survive_queue_and_conflict_on_same_key(self):
        value = {**payload(), 'model': 'gpt-6.1-terra', 'reasoning_effort': 'high'}
        key = str(uuid4())
        request = self.submit(value, key)
        stored = self.repo.request(request['request_id'])
        self.assertEqual(stored['model'], value['model'])
        self.assertEqual(stored['reasoning_effort'], 'high')
        self.service.execute(request['request_id'])
        self.assertEqual(self.provider.run.call_args.args[2:],
                         ('gpt-6.1-terra', self.service.policy.output_tokens, 'high'))
        self.assertEqual(self.submit(value, key)['state'], 'succeeded')
        with self.assertRaises(CloudError):
            self.submit({**value, 'reasoning_effort': 'low'}, key)
        self.provider.run.assert_called_once()

    def test_model_settings_require_both_fields_and_valid_combination_for_both_request_kinds(self):
        from backend.translation.contract import validate_input, inference_settings
        for kind in ['context', 'word']:
            value = payload()
            if kind == 'word':
                value.pop('words_to_explain'); value['lemma'] = value['selected_text']
            for fields in [{'model': 'gpt-5-mini'}, {'reasoning_effort': 'low'},
                           {'model': 'gpt-6.1-sol', 'reasoning_effort': 'none'},
                           {'model': 'unknown', 'reasoning_effort': 'high'},
                           {'model': None, 'reasoning_effort': 'minimal'}]:
                with self.assertRaises(CloudError): validate_input(kind, {**value, **fields})
            selected = validate_input(kind, {**value, 'model': 'gpt-5-nano', 'reasoning_effort': 'low'})
            self.assertEqual(inference_settings(selected), ('gpt-5-nano', 'low'))
            self.assertEqual(inference_settings(validate_input(kind, value), 'gpt-5-nano'),
                             ('gpt-5-nano', 'minimal'))

    def test_purchase_catalogue_requires_enabled_configured_products(self):
        from backend.billing import api as billing_api
        from backend.billing.service import BillingService
        from backend.cloud.identity import Identity
        identity=Mock(); identity.authenticate.return_value=Identity('alice','apple_alice')
        billing_service=BillingService(self.billing,None,clock=lambda:self.now)
        with patch.object(billing_api.runtime,'identity',return_value=identity),patch.object(billing_api.runtime,'service',return_value=billing_service),patch.dict('os.environ',{'APPLE_PRODUCTS':'["monthly"]'}):
            for enabled in [False,True]:
                with patch('backend.translation.runtime.policy',return_value=replace(self.service.policy,enabled=enabled)):
                    response=billing_api.account_handler({'routeKey':'GET /v1/products'},None)
                self.assertEqual(200,response['statusCode'])
                value=json.loads(response['body'])
                self.assertEqual(enabled,value['purchases_enabled'])
                self.assertEqual([{'id':'monthly','translations':3,'alignments':2}],value['products'])
            with patch('backend.translation.runtime.policy',return_value=self.service.policy),patch.dict('os.environ',{'APPLE_PRODUCTS':'[]'}):
                value=json.loads(billing_api.account_handler({'routeKey':'GET /v1/products'},None)['body'])
                self.assertFalse(value['purchases_enabled']); self.assertEqual([],value['products'])

    def test_replay_and_queue_duplicates_submit_and_settle_once(self):
        key = str(uuid4()); first = self.submit(key=key)
        self.assertEqual(first, self.submit(key=key))
        self.service.execute(first['request_id']); self.service.execute(first['request_id'])
        self.assertEqual(1, self.provider.run.call_count)
        stored = self.repo.request(first['request_id'])
        self.assertTrue(stored['settled']); self.assertEqual('succeeded', stored['state'])
        self.assertEqual(1, self.repo.counter(stored['quota_key']))
        self.assertEqual(0, self.repo.counter('active:global'))
        self.assertNotIn('input', self.repo.content(first['request_id']))
        self.assertNotIn('selected_text', stored)
        self.assertIn('result', self.service.status('alice', first['request_id']))

    def test_different_payload_or_operation_conflicts(self):
        key = str(uuid4()); self.submit(key=key)
        with self.assertRaises(CloudError) as error: self.submit(payload('dog'), key)
        self.assertEqual('IDEMPOTENCY_CONFLICT', error.exception.code)

    @unittest.skipUnless(os.environ.get('DYNAMODB_LOCAL_URL'), 'Concurrency requires DynamoDB Local; Moto is not transaction-isolated across threads')
    def test_concurrent_reservations_never_exceed_allowance(self):
        def attempt(_):
            try: return self.submit()['request_id']
            except CloudError: return None
        with ThreadPoolExecutor(max_workers=8) as pool: ids = list(pool.map(attempt, range(12)))
        accepted=len([i for i in ids if i])
        self.assertGreater(accepted,0); self.assertLessEqual(accepted,3)
        self.assertEqual(accepted,self.repo.counter('quota:alice:translations:2026-11'))

    def test_lost_post_response_recovers_by_owner_scoped_idempotency_key(self):
        key=str(uuid4()); original=self.submit(key=key)
        self.assertEqual(original,self.service.status_by_key('alice',key))
        self.billing.account('bob')
        with self.assertRaises(CloudError) as error: self.service.status_by_key('bob',key)
        self.assertEqual(404,error.exception.status)

    def test_policy_version_change_cannot_refill_monthly_allowance(self):
        for _ in range(3):
            request_id=self.submit()['request_id']; self.service.execute(request_id)
        self.service.policy=replace(self.service.policy,version='cloud-v2')
        with self.assertRaises(CloudError): self.submit()
        self.assertEqual(3,self.repo.counter('quota:alice:translations:2026-11'))

    def test_owner_checks_and_expired_subscription_retrieval(self):
        request_id = self.submit()['request_id']; self.service.execute(request_id)
        self.billing.account('bob')
        with self.assertRaises(CloudError) as error: self.service.status('bob', request_id)
        self.assertEqual(404, error.exception.status)
        self.billing.save_subscription(self.account, replace(self.subscription, status='expired'), self.billing.subscription('chain'))
        self.assertIn('result', self.service.status('alice', request_id))
        with self.assertRaises(CloudError): self.submit()

    def test_revocation_between_read_and_transaction_cannot_admit(self):
        original = self.repo.admit
        def revoked(*args):
            self.billing.save_subscription(self.account, replace(self.subscription, status='revoked'), self.billing.subscription('chain'))
            return original(*args)
        self.repo.admit = revoked
        with self.assertRaises(CloudError): self.submit()
        self.assertEqual(0, self.repo.counter('active:global'))

    def test_crash_before_dispatch_is_recovered_from_durable_intent(self):
        request_id = self.submit()['request_id']; queued = []
        self.service.maintain(self.repo.request(request_id), queued.append)
        self.assertEqual([request_id], queued)
        self.service.execute(queued[0]); self.assertEqual(1, self.provider.run.call_count)

    def test_crash_after_claim_never_resubmits_and_watchdog_refunds(self):
        request_id = self.submit()['request_id']
        self.provider.run.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt): self.service.execute(request_id)
        self.service.execute(request_id)
        self.assertEqual(1, self.provider.run.call_count)
        self.now += 121
        self.service.maintain(self.repo.request(request_id), lambda _: self.fail('must not queue running work'))
        record = self.repo.request(request_id)
        self.assertEqual('outcome_unknown', record['state'])
        self.assertEqual(0, self.repo.counter(record['quota_key']))
        self.assertIsNone(self.repo.content(request_id))
        self.service.execute(request_id); self.assertEqual(1, self.provider.run.call_count)

    def test_lost_response_after_successful_persistence_is_safe(self):
        request_id = self.submit()['request_id']; original = self.repo.finish
        def lost(*args, **kwargs):
            original(*args, **kwargs)
            raise OSError('lost database acknowledgment')
        self.repo.finish = lost
        with self.assertRaises(OSError): self.service.execute(request_id)
        self.repo.finish = original
        self.service.execute(request_id)
        self.assertEqual(1, self.provider.run.call_count)
        self.assertEqual('succeeded', self.repo.request(request_id)['state'])

    def test_known_failure_and_unknown_outcome_refund_user_but_keep_global_admission(self):
        for unknown in [False, True]:
            request_id = self.submit()['request_id']
            self.provider.run.side_effect = ProviderFailure(unknown)
            self.service.execute(request_id)
            record = self.repo.request(request_id)
            self.assertEqual('outcome_unknown' if unknown else 'failed', record['state'])
            self.assertEqual(0, self.repo.counter(record['quota_key']))
        self.assertEqual(2, self.repo.counter(f'day:global:{self.now // 86400}'))

    def test_cancel_and_late_worker_never_double_settle(self):
        request_id = self.submit()['request_id']; old = self.repo.request(request_id)
        self.service.cancel('alice', request_id); self.service.cancel('alice', request_id)
        self.repo.finish(old, 'failed', self.now)
        self.service.execute(request_id)
        self.provider.run.assert_not_called()
        self.assertEqual(0, self.repo.counter('active:global'))

    def test_deleted_account_cannot_claim_or_publish_result(self):
        request_id = self.submit()['request_id']; self.billing.disable_account('alice')
        self.service.execute(request_id); self.provider.run.assert_not_called()
        self.assertEqual('cancelled', self.repo.request(request_id)['state'])
        with self.assertRaises(CloudError): self.service.status('alice', request_id)

    def test_deletion_during_provider_call_discards_content(self):
        request_id = self.submit()['request_id']
        def deleting(kind, value, *_):
            self.billing.disable_account('alice')
            return result(value), {}
        self.provider.run.side_effect = deleting
        self.service.execute(request_id)
        self.assertEqual('cancelled', self.repo.request(request_id)['state'])
        self.assertIsNone(self.repo.content(request_id))

    def test_expiry_is_enforced_before_physical_cleanup(self):
        request_id = self.submit()['request_id']; self.service.execute(request_id)
        self.now += 86401
        with self.assertRaises(CloudError) as error: self.service.status('alice', request_id)
        self.assertEqual(410, error.exception.status)
        self.service.maintain(self.repo.request(request_id), lambda _: None)
        self.assertIsNone(self.repo.content(request_id))

    def test_quota_period_is_pinned_across_month_reset(self):
        self.now = int(datetime.datetime(2026, 11, 30, 23, 59, 30, tzinfo=datetime.timezone.utc).timestamp())
        self.billing.save_subscription(self.account, replace(self.subscription, verified_at=self.now), self.billing.subscription('chain'))
        request_id = self.submit()['request_id']; self.now += 60
        self.service.execute(request_id)
        self.assertEqual(1, self.repo.counter('quota:alice:translations:2026-11'))
        self.assertEqual(0, self.repo.counter('quota:alice:translations:2026-12'))

    def test_incompatible_policy_never_submits_old_intent_with_new_prompts(self):
        request_id=self.submit()['request_id']
        self.service.policy=policy(model='gpt-5-nano')
        self.service.execute(request_id)
        self.provider.run.assert_not_called()
        self.assertEqual('cancelled',self.repo.request(request_id)['state'])
        self.assertEqual(0,self.repo.counter('active:global'))

    def test_kill_switch_preserves_replay_and_admitted_work(self):
        key = str(uuid4()); request_id = self.submit(key=key)['request_id']
        self.service.policy = replace(self.service.policy, enabled=False)
        self.assertEqual(request_id, self.submit(key=key)['request_id'])
        with self.assertRaises(CloudError): self.submit()
        self.service.execute(request_id)
        self.assertEqual('succeeded', self.repo.request(request_id)['state'])


class ContractTests(unittest.TestCase):
    def test_utf16_supplementary_and_six_languages_repeated_words(self):
        for language, words in [('en','cat cat'),('fr','chat chat'),('es','gato gato'),('de','Haus Haus'),('it','gatto gatto'),('pl','kot kot')]:
            value = payload(words, '😀 ' + words, language)
            value['selection_location_utf16'] = 3
            validate_input('context', value); validate_output('context', result(value), value)
        invalid = payload('😀', '😀x'); invalid['selection_location_utf16'] = 1
        with self.assertRaises(CloudError): validate_input('context', invalid)
        value = payload('😀'); self.assertEqual(2, value['selection_length_utf16'])
        validate_input('context', value)

    def test_oversized_unordered_repeated_and_unknown_fields_rejected(self):
        cases = [payload('😀' * 129), {**payload(), 'user_id':'bob'}, {**payload(), 'model':'arbitrary'},
            {**payload(), 'words_to_explain':['cat','cat','cat']}, {**payload(), 'schema_version':True},
            {**payload(), 'source_language':[]}, {**payload(), 'context':'x'*1401}]
        for value in cases:
            with self.assertRaises(CloudError): validate_input('context', value)
        value = payload('cat dog'); value['words_to_explain'] = ['dog','cat']
        with self.assertRaises(CloudError): validate_input('context', value)

    def test_invalid_word_outputs_and_explanation_injection_rejected(self):
        value = payload(); answer = result(value); answer['word_explanations'][0]['source_word'] = 'other'
        with self.assertRaises(CloudError): validate_output('context', answer, value)
        answer = result(value); answer['word_explanations'][0]['lemma'] = 'line\nbreak'
        with self.assertRaises(CloudError): validate_output('context', answer, value)
        with self.assertRaises(CloudError): validate_output('word', {'definition':'x','meaningInContext':'x','examples':[]}, {})

    def test_provider_payload_is_fixed_bounded_and_not_stored(self):
        calls = []
        def opener(request, timeout):
            calls.append((json.loads(request.data), timeout))
            return io.BytesIO(json.dumps({'status':'completed','output':[{'content':[{'type':'output_text',
                'text':json.dumps(result(payload()))}]}], 'usage':{'input_tokens':2,'output_tokens':3}}).encode())
        provider = OpenAIProvider('test-key', opener)
        _, usage = provider.run('context', payload(), 'gpt-5-mini', 2048)
        sent, timeout = calls[0]
        self.assertFalse(sent['store']); self.assertEqual(45, timeout)
        self.assertNotIn('tools', sent); self.assertEqual(2048, sent['max_output_tokens'])
        self.assertEqual(3, usage['output_tokens'])

    def test_provider_timeout_has_no_automatic_retry(self):
        opener = Mock(side_effect=TimeoutError())
        with self.assertRaises(ProviderFailure) as error: OpenAIProvider('key', opener).run('context', payload(), 'gpt-5-mini', 2048)
        self.assertTrue(error.exception.unknown); self.assertEqual(1, opener.call_count)

    def test_calendar_annual_monthly_policy_and_invalid_limits(self):
        self.assertEqual('2026-11', period(1793491200)[0])
        with self.assertRaises(ValueError): policy(output_tokens=100000)
        with self.assertRaises(ValueError): policy(model='unrestricted-model')
