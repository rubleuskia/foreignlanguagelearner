import unittest
from uuid import uuid4
from dataclasses import replace
from backend.translation import test_translation as fixture
from backend.alignment.test_service import Storage, Workflow, request, bearer
from backend.alignment.service import AlignmentService
from backend.alignment.errors import NotFound
from backend.cloud.errors import CloudError
from backend.paid_alignment.repository import PaidRepository
from backend.paid_alignment.service import AccountAlignmentService


class PaidAlignmentTests(unittest.TestCase):
    def setUp(self):
        fixture.TranslationTests.setUp(self)
        table = 'jobs' + uuid4().hex
        self.client.create_table(TableName=table, KeySchema=[{'AttributeName':'pk','KeyType':'HASH'}, {'AttributeName':'sk','KeyType':'RANGE'}],
            AttributeDefinitions=[{'AttributeName':'pk','AttributeType':'S'}, {'AttributeName':'sk','AttributeType':'S'}], BillingMode='PAY_PER_REQUEST')
        self.addCleanup(lambda:self.client.delete_table(TableName=table))
        self.jobs = PaidRepository(self.client, table, self.repo, self.billing, self.service.policy, 'alice')
        self.storage, self.workflow = Storage(), Workflow()
        self.alignment = self.for_owner('alice')

    def for_owner(self, owner):
        return AccountAlignmentService(self.jobs, self.storage, self.workflow, owner=owner, usage=self.repo,
            bucket='bucket', state_machine_arn='arn:version:1', accept_new_jobs=True, clock=lambda:self.now)

    def create(self): return self.alignment.create(request(), None, str(uuid4()))[1]['job_id']
    def complete(self, job_id): self.alignment.complete_upload(job_id, {'parts':[{'part_number':1,'etag':'etag'}]}, None)

    def test_owner_on_all_operations_and_no_capability_adoption(self):
        job_id = self.create(); self.billing.account('bob'); foreign = self.for_owner('bob')
        actions = [lambda:foreign.status(job_id,None), lambda:foreign.upload_status(job_id,None),
            lambda:foreign.upload_urls(job_id, {'part_numbers':[1]},None), lambda:foreign.complete_upload(job_id,{},None),
            lambda:foreign.result(job_id,None), lambda:foreign.diagnostics(job_id,None), lambda:foreign.cancel(job_id,{},None)]
        for action in actions:
            with self.assertRaises(NotFound): action()
        legacy = AlignmentService(self.jobs,self.storage,self.workflow,bucket='bucket',state_machine_arn='arn:version:1',accept_new_jobs=True)
        with self.assertRaises(NotFound): legacy.status(job_id,bearer(1))

    def test_create_replay_and_multiple_jobs_for_one_account(self):
        key = str(uuid4()); _, first = self.alignment.create(request(),None,key)
        _, again = self.alignment.create(request(),None,key)
        self.assertEqual(first['job_id'],again['job_id'])
        second = self.create(); self.assertNotEqual(first['job_id'],second)
        self.assertEqual(2,self.repo.counter('quota:alice:alignments:2026-11'))
        with self.assertRaises(CloudError): self.create()

    def test_expiry_refunds_reservation_once(self):
        job_id = self.create(); job = self.jobs.get_job(job_id)
        self.jobs.expire_upload(job,self.now+86401)
        self.jobs.expire_upload(self.jobs.get_job(job_id),self.now+86402)
        self.assertEqual(0,self.repo.counter(job['paid_reservation']['quota_key']))
        self.assertEqual(0,self.repo.counter('active:global'))
        self.assertTrue(self.jobs.get_job(job_id)['paid_settled'])

    def test_start_requires_current_access_and_reserves_only_once(self):
        job_id=self.create(); self.complete(job_id)
        self.billing.save_subscription(self.account,replace(self.subscription,status='expired'),self.billing.subscription('chain'))
        with self.assertRaises(CloudError): self.alignment.start(job_id,{},None)
        self.assertEqual([],self.workflow.starts)
        self.billing.save_subscription(self.account,self.subscription,self.billing.subscription('chain'))
        self.alignment.start(job_id,{},None); self.alignment.start(job_id,{},None)
        self.assertEqual(1,len(self.workflow.starts))
        self.assertEqual(1,self.repo.counter('quota:alice:alignments:2026-11'))

    def test_finish_after_subscription_expiry_charges_original_period_once(self):
        job_id=self.create(); self.complete(job_id); self.alignment.start(job_id,{},None)
        self.billing.save_subscription(self.account,replace(self.subscription,status='expired'),self.billing.subscription('chain'))
        job=self.jobs.get_job(job_id)
        self.jobs.finalize(job,status='succeeded',now=self.now+100,manifest={'artifacts':{},'requires_review':False,'counts':{}})
        self.jobs.finalize(self.jobs.get_job(job_id),status='succeeded',now=self.now+101)
        self.assertEqual(1,self.repo.counter(job['paid_reservation']['quota_key']))
        self.assertEqual(0,self.repo.counter('active:global'))
        self.assertEqual('succeeded',self.alignment.status(job_id,None)['status'])

    def test_cancel_and_failure_release_once_without_replacing_global_caps(self):
        job_id=self.create(); self.complete(job_id); self.alignment.start(job_id,{},None)
        self.alignment.cancel(job_id,{},None)
        job=self.jobs.get_job(job_id)
        self.jobs.finalize(job,status='cancelled',now=self.now)
        self.assertEqual(0,self.repo.counter(job['paid_reservation']['quota_key']))
        self.assertEqual(0,self.jobs._counter('COUNTER#ACTIVE'))
        self.assertEqual(1,self.jobs._counter('COUNTER#STARTS#2026-11-01'))

    def test_deletion_blocks_access_and_success_publishing(self):
        job_id=self.create(); self.complete(job_id); self.alignment.start(job_id,{},None)
        self.billing.disable_account('alice')
        with self.assertRaises(CloudError): self.alignment.status(job_id,None)
        job=self.jobs.get_job(job_id)
        self.jobs.finalize(job,status='succeeded',now=self.now,manifest={'artifacts':{'private':{}}})
        final=self.jobs.get_job(job_id)
        self.assertEqual('cancelled',final['status']); self.assertNotIn('artifacts',final)
        self.assertEqual(0,self.repo.counter(job['paid_reservation']['quota_key']))
