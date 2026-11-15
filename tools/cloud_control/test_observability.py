"""SDK-backed telemetry and local HTTP relay regression coverage; no live AWS calls."""
import copy
from datetime import datetime, timedelta, timezone
import http.client
import hashlib
import json
import io
from pathlib import Path
import tempfile
import tarfile
import time
import threading
import unittest
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer

import boto3
from botocore.config import Config
from botocore.stub import Stubber
from moto import mock_aws

from .config import ControlError, Configuration, digest, atomic_json
from .deployment import prepared_changes, summary, template_changes
from .monitoring import Monitoring, normalize_job, redact
from .openapi import manual, specification
from .server import Application, Handler
from .worker_image import inspect as inspect_image, download_config, CONTRACT_LABEL, REVISION_LABEL
from .jobs import Jobs, tree_digest

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 14, 12, tzinfo=timezone.utc)
ACCOUNT = '123456789012'
API = 'https://test.execute-api.eu-north-1.amazonaws.com'
FOUNDATION = 'ForeignLanguageLearnerOperator-prod'
ALIGNMENT = 'ForeignLanguageLearnerOperatorAlignment-prod'
CONFIG = {'account_id': ACCOUNT, 'region': 'eu-north-1', 'profile': 'test', 'deployment_mode': 'operator',
    'context': {'operatorAlignment': 'true', 'workerRepositoryName': 'worker', 'workerImageDigest': 'sha256:' + 'a' * 64,
                'openaiSecretArn': 'arn:aws:secretsmanager:eu-north-1:123456789012:secret:openai-AbCdEf'},
    'alignment_benchmark_file': '/tmp/benchmark.json'}
DISCOVERY = {'stacks': [{'name': FOUNDATION, 'status': 'UPDATE_COMPLETE', 'tags': {'ControlRevision': 'b' * 40},
                        'outputs': {'ApiUrl': API}}, {'name': ALIGNMENT, 'status': 'NOT_DEPLOYED', 'tags': {}, 'outputs': {}}],
             'resources': [], 'warnings': []}
ROUTES = [{'RouteKey': 'GET /v1/me', 'AuthorizationType': 'JWT'},
          {'RouteKey': 'GET /v1/requests/{id}', 'AuthorizationType': 'JWT'},
          {'RouteKey': 'POST /v1/context-analyses', 'AuthorizationType': 'JWT'},
          {'RouteKey': 'POST /v1/book-alignments', 'AuthorizationType': 'JWT'}]


def resource(kind, name, logical=None):
    return {'type': 'AWS::' + kind, 'id': name, 'logical_id': logical or name, 'stack': ALIGNMENT}


def session():
    return boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name='eu-north-1')


def fake_aws():
    aws = Mock(); aws.config = copy.deepcopy(CONFIG); aws.options = Config(retries={'total_max_attempts': 1})
    aws.session = session()
    aws.client = lambda name: aws.session.client(name, config=aws.options)
    return aws


class CostsTests(unittest.TestCase):
    def test_sdk_pagination_decimal_dates_and_account_scope(self):
        aws = fake_aws(); client = aws.session.client('ce', region_name='us-east-1')
        base = {'TimePeriod': {'Start': '2026-11-01', 'End': '2026-11-15'}, 'Granularity': 'DAILY',
                'Metrics': ['UnblendedCost'], 'GroupBy': [{'Type': 'DIMENSION', 'Key': 'SERVICE'}],
                'Filter': {'Dimensions': {'Key': 'LINKED_ACCOUNT', 'Values': [ACCOUNT]}}}
        def page(value, token=None):
            return {'ResultsByTime': [{'TimePeriod': {'Start': '2026-11-13', 'End': '2026-11-14'},
                'Estimated': True, 'Groups': [{'Keys': ['Amazon S3'], 'Metrics': {'UnblendedCost': {'Amount': value, 'Unit': 'USD'}}}]}],
                **({'NextPageToken': token} if token else {})}
        with Stubber(client) as stub:
            stub.add_response('get_cost_and_usage', page('0.10', 'next'), base)
            stub.add_response('get_cost_and_usage', page('0.20'), {**base, 'NextPageToken': 'next'})
            with patch.object(aws.session, 'client', return_value=client):
                result = Monitoring(aws, now=NOW)._cost_usage()
            stub.assert_no_pending_responses()
        self.assertEqual(result['total'], '0.30'); self.assertEqual(result['daily'][0]['amount'], '0.30')
        self.assertTrue(result['estimated'])

    def test_empty_data_is_not_a_zero_bill_and_plan_survives_ce_denial(self):
        aws = fake_aws()
        plan = Mock(); plan.get_account_plan_state.return_value = {'accountId': ACCOUNT, 'accountPlanType': 'FREE',
            'accountPlanStatus': 'ACTIVE', 'accountPlanRemainingCredits': {'amount': 10.5, 'unit': 'USD'}}
        with patch.object(aws.session, 'client', return_value=plan), patch.object(Monitoring, '_cost_usage', side_effect=RuntimeError()):
            result = Monitoring(aws, now=NOW).costs()
        self.assertIsNone(result['total']); self.assertEqual(result['plan']['remaining_credits'], '10.5')
        self.assertEqual(result['warnings'][0]['source'], 'Cost Explorer')
        with patch.object(aws.session, 'client', return_value=plan), patch.object(Monitoring, '_cost_usage', return_value={'total': '0', 'currency': 'USD'}):
            plan.get_account_plan_state.return_value = {'accountId': '999999999999'}
            result = Monitoring(aws, now=NOW).costs()
        self.assertIsNone(result['plan']); self.assertEqual(result['total'], '0')


class ScopeAndCacheTests(unittest.TestCase):
    def test_discovery_scopes_stacks_and_includes_imported_storage(self):
        aws = fake_aws()
        aws.snapshot.return_value = [*copy.deepcopy(DISCOVERY['stacks']),
            {'name': 'Unrelated', 'status': 'CREATE_COMPLETE', 'outputs': {}}]
        aws.snapshot.return_value[0]['outputs']['BookLibraryBucket'] = 'imported-books'
        client = Mock()
        from botocore.exceptions import ClientError
        client.describe_stacks.side_effect = ClientError(
            {'Error': {'Code': 'ValidationError', 'Message': 'Stack does not exist'}}, 'DescribeStacks')
        client.get_paginator.return_value.paginate.return_value = [
            {'StackResourceSummaries': [{'LogicalResourceId': 'Api', 'ResourceType': 'AWS::ApiGatewayV2::Api', 'PhysicalResourceId': 'api'}]},
            {'StackResourceSummaries': [{'LogicalResourceId': 'Logs', 'ResourceType': 'AWS::Logs::LogGroup', 'PhysicalResourceId': 'logs'}]}]
        aws.client = Mock(return_value=client)
        result = Monitoring(aws).discover()
        self.assertEqual({r['id'] for r in result['resources']}, {'api', 'logs', 'imported-books'})
        client.get_paginator.return_value.paginate.assert_called_once_with(StackName=FOUNDATION)
        self.assertFalse(result['warnings'])

    def test_scan_limit_reports_partial_coverage(self):
        aws = fake_aws(); native = Mock()
        native.get_paginator.return_value.paginate.return_value = [
            {'Items': [], 'LastEvaluatedKey': {'job_id': 'more'}} for _ in range(51)]
        discovery = {**DISCOVERY, 'resources': [resource('DynamoDB::Table', 'jobs', 'BooksRequests')]}
        with patch.object(aws.session, 'resource', return_value=Mock(meta=Mock(client=native))):
            result = Monitoring(aws, discovery, NOW).alignment()
        self.assertFalse(result['complete']); self.assertFalse(result['sources'][0]['complete'])

    def test_cache_separates_configs_and_shortens_failure_ttl(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Application(ROOT, temp); call = Mock(return_value={'available': False})
            with patch('tools.cloud_control.server.time.monotonic', return_value=100):
                app.cached('costs', CONFIG, call, 900)
            with patch('tools.cloud_control.server.time.monotonic', return_value=116):
                app.cached('costs', CONFIG, call, 900)
                app.cached('costs', {**CONFIG, 'profile': 'other'}, call, 900)
            self.assertEqual(call.call_count, 3)
            app.jobs.releases.list = Mock(return_value=[])
            app.tags([]); app.tags([])
            app.jobs.releases.list.assert_called_once()
            app.tags([{'id': 'new-refresh', 'action': 'refresh', 'state': 'passed'}])
            self.assertEqual(app.jobs.releases.list.call_count, 2)

    def test_repeated_api_description_uses_cached_route_list(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Application(ROOT, temp); app.configuration.save(CONFIG)
            app.discovery = Mock(return_value=DISCOVERY)
            with patch('tools.cloud_control.server.AWS'), patch('tools.cloud_control.server.Monitoring') as monitor:
                monitor.return_value.routes.return_value = ROUTES
                self.assertEqual(app.api_description()[2], ROUTES)
                self.assertEqual(app.api_description()[2], ROUTES)
                monitor.return_value.routes.assert_called_once()


@mock_aws
class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.aws = fake_aws(); self.discovery = copy.deepcopy(DISCOVERY)

    def test_s3_native_pagination_and_scoped_buckets(self):
        s3 = self.aws.client('s3'); s3.create_bucket(Bucket='owned-bucket', CreateBucketConfiguration={'LocationConstraint': 'eu-north-1'})
        for i in range(103): s3.put_object(Bucket='owned-bucket', Key=f'books/{i:03}', Body=b'abc')
        self.discovery['resources'] = [resource('S3::Bucket', 'owned-bucket'), resource('S3::Bucket', 'owned-bucket', 'ImportedBucket')]
        monitor = Monitoring(self.aws, self.discovery)
        first = monitor.storage(prefix='books/'); second = monitor.storage(bucket='owned-bucket', prefix='books/', cursor=first['cursor'])
        self.assertEqual(len(first['files']), 100); self.assertEqual(first['page_bytes'], 300)
        self.assertEqual(len(first['buckets']), 1)
        self.assertEqual(len(second['files']), 3); self.assertIsNone(second['cursor'])
        with self.assertRaises(ControlError): monitor.storage(bucket='foreign-bucket')

    def test_dynamodb_native_paginator_filters_creation_and_hides_capabilities(self):
        ddb = self.aws.session.resource('dynamodb')
        for name, keys in [('book-jobs', ['owner', 'job_id']), ('legacy-jobs', ['pk', 'sk'])]:
            ddb.create_table(TableName=name, BillingMode='PAY_PER_REQUEST',
                KeySchema=[{'AttributeName': keys[0], 'KeyType': 'HASH'}, {'AttributeName': keys[1], 'KeyType': 'RANGE'}],
                AttributeDefinitions=[{'AttributeName': key, 'AttributeType': 'S'} for key in keys])
        now = int(NOW.timestamp())
        ddb.Table('book-jobs').put_item(Item={'owner': 'system', 'job_id': 'book', 'created_at': now-3000,
            'updated_at': now-1000, 'status': 'succeeded', 'attempts': 2, 'size_bytes': 1000,
            'history': [{'status': 'queued', 'at': now-2900}, {'status': 'downloading', 'at': now-2800}], 'secret': 'do-not-return'})
        ddb.Table('book-jobs').put_item(Item={'owner': 'system', 'job_id': 'old', 'created_at': now-100*86400,
            'updated_at': now, 'status': 'failed'})
        ddb.Table('legacy-jobs').put_item(Item={'pk': 'JOB#legacy', 'sk': 'METADATA', 'job_id': 'legacy',
            'created_at': now-2000, 'completed_at': now-1000, 'worker_claimed_at': now-1200, 'status': 'succeeded',
            'expected_audio_bytes': 200, 'expected_text_bytes': 10, 'access_token_hash': 'capability-secret'})
        self.discovery['resources'] = [resource('DynamoDB::Table', 'book-jobs', 'BooksRequests'),
                                       resource('DynamoDB::Table', 'legacy-jobs', 'JobsTable')]
        result = Monitoring(self.aws, self.discovery, NOW).alignment()
        self.assertEqual(result['requests'], 2); self.assertEqual(result['executions'], 3)
        self.assertEqual(result['mean_runtime_seconds'], 1000); self.assertEqual(result['input_bytes'], 1210)
        self.assertEqual(next(r for r in result['jobs'] if r['job_id']=='book')['queue_seconds'], 100)
        self.assertTrue(result['complete']); self.assertNotIn('secret', json.dumps(result))

    def test_api_metrics_and_log_false_positives_and_partial_access(self):
        self.discovery['resources'] = [resource('ApiGatewayV2::Api', 'api'), resource('Logs::LogGroup', 'access', 'AccessLogs')]
        cw, logs = Mock(), Mock()
        cw.get_metric_statistics.side_effect = [{'Datapoints': [{'Sum': 10}]}, {'Datapoints': [{'Sum': 2}]}]
        logs.filter_log_events.return_value = {'events': [
            {'message': '{"status":"200","latency":500}', 'timestamp': 1, 'eventId': 'ok'},
            {'message': '{"status":"500","requestId":"id"}', 'timestamp': 2, 'eventId': 'bad'}], 'nextToken':'next'}
        self.aws.client = lambda name: {'cloudwatch':cw,'logs':logs}[name]
        result = Monitoring(self.aws, self.discovery, NOW).errors()
        self.assertEqual(result['metrics'][0]['errors_5xx'],2); self.assertEqual(len(result['events']),1)
        self.assertEqual(result['cursor'],'next')
        with self.assertRaises(ControlError): Monitoring(self.aws,self.discovery,NOW).errors(group='foreign')
        logs.filter_log_events.side_effect = RuntimeError()
        cw.get_metric_statistics.side_effect = None; cw.get_metric_statistics.return_value = {'Datapoints': []}
        result = Monitoring(self.aws,self.discovery,NOW).errors()
        self.assertTrue(result['warnings']); self.assertIsNone(result['metrics'][0]['errors_5xx'])

    def test_error_periods_apply_same_window_to_metrics_and_paginated_logs(self):
        self.discovery['resources'] = [resource('ApiGatewayV2::Api', 'api'), resource('Logs::LogGroup', 'access', 'AccessLogs')]
        for hours in [1, 24, 168, 720]:
            with self.subTest(hours=hours):
                cw, logs = Mock(), Mock()
                cw.get_metric_statistics.return_value = {'Datapoints': [{'Sum': 2}, {'Sum': 3}]}
                logs.filter_log_events.return_value = {'events': [], 'nextToken': 'next'}
                self.aws.client = lambda name: {'cloudwatch': cw, 'logs': logs}[name]
                result = Monitoring(self.aws, self.discovery, NOW).errors(hours=hours, cursor='previous')
                start = NOW - timedelta(hours=hours)
                self.assertEqual(result['hours'], hours)
                self.assertEqual(result['metrics'][0]['errors_5xx'], 5)
                self.assertEqual(result['cursor'], 'next')
                for call in cw.get_metric_statistics.call_args_list:
                    self.assertEqual(call.kwargs['StartTime'], start)
                    self.assertEqual(call.kwargs['EndTime'], NOW)
                    self.assertEqual(call.kwargs['Period'], 3600)
                params = logs.filter_log_events.call_args.kwargs
                self.assertEqual(params['startTime'], int(start.timestamp() * 1000))
                self.assertEqual(params['endTime'], int(NOW.timestamp() * 1000))
                self.assertEqual(params['nextToken'], 'previous')
        with self.assertRaises(ControlError): Monitoring(self.aws, self.discovery, NOW).errors(hours=25)

    def test_missing_duration_and_common_secrets_are_not_exposed(self):
        self.assertIsNone(normalize_job({'job_id':'empty','created_at':1},'table',10)['runtime_seconds'])
        value=redact('eyJabc.def.ghi AKIA'+'X'*16+' Bearer tokenvalue '+json.dumps({'refreshToken':'private','password':'hidden'}))
        for hidden in ['eyJabc','AKIA','tokenvalue','private','hidden']: self.assertNotIn(hidden,value)


class WorkerImageTests(unittest.TestCase):
    def test_prepare_blocks_old_image_before_building_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            config=copy.deepcopy(CONFIG);benchmark=Path(temp)/'benchmark.json';benchmark.write_text('{}')
            config['alignment_benchmark_file']=str(benchmark)
            aws=Mock();aws.snapshot.return_value=[]
            aws.client.return_value.describe_availability_zones.return_value={'AvailabilityZones':[{'ZoneName':'eu-north-1a'},{'ZoneName':'eu-north-1b'}]}
            aws.require_book_worker.side_effect=ControlError('old image: book-queue-v1')
            releases=Mock();releases.verify.return_value={'tag':'test','sha':'a'*40}
            jobs=Jobs(ROOT,Configuration(temp),aws_factory=lambda _:aws,releases=releases);key='a'*32
            atomic_json(jobs.directory/(key+'.json'),{'id':key,'state':'running','log':''})
            def archive(operation,argv,**kwargs):
                self.assertEqual(argv[:2],['git','archive'])
                with tarfile.open(argv[4],'w') as bundle:
                    item=tarfile.TarInfo('backend/book_alignment/api.py');item.size=1
                    bundle.addfile(item,io.BytesIO(b'x'))
            jobs.execute=Mock(side_effect=archive)
            with patch('tools.cloud_control.jobs.validate_benchmark'),self.assertRaisesRegex(ControlError,'book-queue-v1'):
                jobs.prepare(key,config,{'tag':'test'})
            jobs.execute.assert_called_once();aws.require_book_worker.assert_called_once()

    def test_existing_ready_plan_rechecks_image_before_consumption_or_cdk(self):
        with tempfile.TemporaryDirectory() as temp:
            aws=Mock();aws.snapshot.return_value=DISCOVERY['stacks']
            aws.require_book_worker.side_effect=ControlError('old image: book-queue-v1')
            releases=Mock();releases.verify.return_value={'sha':'a'*40}
            jobs=Jobs(ROOT,Configuration(temp),aws_factory=lambda _:aws,releases=releases)
            plan_id='a'*32;operation='b'*32;area=jobs.plans/plan_id
            source=area/'source/backend/book_alignment/api.py';source.parent.mkdir(parents=True);source.write_text('')
            plan={'id':plan_id,'action':'prepare','state':'ready','tag':'test','sha':'a'*40,'prepared_at':time.time(),
                  'config_hash':digest(CONFIG),'artifact_hash':tree_digest(area),'baseline':DISCOVERY['stacks']}
            atomic_json(jobs.directory/(plan_id+'.json'),plan)
            atomic_json(jobs.directory/(operation+'.json'),{'id':operation,'state':'running','log':''})
            jobs.execute=Mock()
            with self.assertRaisesRegex(ControlError,'book-queue-v1'):
                jobs.deploy(operation,CONFIG,{'plan_id':plan_id,'confirm':ACCOUNT+'/test'})
            self.assertEqual(jobs.get(plan_id)['state'],'ready');jobs.execute.assert_not_called()

    def image(self, change=None):
        config={'os':'linux','architecture':'amd64','config':{'Entrypoint':['python','tools/subtitle-aligner/worker/worker.py'],
            'Labels':{CONTRACT_LABEL:'alignment-input-v1,book-queue-v1',REVISION_LABEL:'b'*40}}}
        if change: change(config)
        raw=json.dumps(config).encode(); sha='sha256:'+hashlib.sha256(raw).hexdigest()
        manifest={'schemaVersion':2,'mediaType':'application/vnd.docker.distribution.manifest.v2+json',
                  'config':{'digest':sha,'size':len(raw)}}
        client=Mock();client.batch_get_image.return_value={'images':[{'imageId':{'imageDigest':'sha256:'+'a'*64},
            'imageManifest':json.dumps(manifest)}]}
        client.get_download_url_for_layer.return_value={'layerDigest':sha,'downloadUrl':'https://private-config'}
        return client,raw

    def inspect(self, client, raw):
        return inspect_image(client,ACCOUNT,'eu-north-1','worker','sha256:'+'a'*64,download=lambda *_:raw)

    def test_compatible_digest_is_verified_without_pulling_layers(self):
        client,raw=self.image();result=self.inspect(client,raw)
        self.assertIn('book-queue-v1',result['contracts']);self.assertEqual(result['source_revision'],'b'*40)
        client.batch_get_image.assert_called_once_with(registryId=ACCOUNT,repositoryName='worker',imageIds=[{'imageDigest':'sha256:'+'a'*64}])
        self.assertEqual(client.get_download_url_for_layer.call_count,1)

    def test_legacy_wrong_platform_and_entrypoint_fail_closed(self):
        for change in [lambda c:c['config'].update(Labels={}),lambda c:c.update(architecture='arm64'),
                       lambda c:c['config'].update(Entrypoint=['python','old.py']),
                       lambda c:c['config']['Labels'].update({REVISION_LABEL:'unknown'})]:
            with self.subTest(change=change),self.assertRaisesRegex(ControlError,'book-queue-v1'):
                self.inspect(*self.image(change))

    def test_config_corruption_or_missing_image_is_rejected(self):
        client,raw=self.image()
        with self.assertRaisesRegex(ControlError,'сумма'):self.inspect(client,raw+b'bad')
        client.batch_get_image.return_value={'images':[],'failures':[{'failureCode':'ImageNotFound'}]}
        with self.assertRaises(ControlError):self.inspect(client,raw)

    def test_oci_index_selects_amd64_and_ignores_attestation(self):
        client,raw=self.image();child=copy.deepcopy(client.batch_get_image.return_value)
        child['images'][0]['imageId']['imageDigest']='sha256:'+'c'*64
        index={'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[
            {'digest':'sha256:'+'c'*64,'platform':{'os':'linux','architecture':'amd64'}},
            {'digest':'sha256:'+'d'*64,'platform':{'os':'unknown','architecture':'unknown'}}]}
        client.batch_get_image.side_effect=[{'images':[{'imageId':{'imageDigest':'sha256:'+'a'*64},'imageManifest':json.dumps(index)}]},child]
        self.assertEqual(self.inspect(client,raw)['platform'],'linux/amd64')
        self.assertEqual(client.batch_get_image.call_count,2)

    def test_config_download_rejects_redirects_and_untrusted_hosts(self):
        for url in ['http://bucket.s3.eu-north-1.amazonaws.com/x','https://evil.test/x',
                    'https://bucket.s3.eu-north-1.amazonaws.com.evil.test/x','https://bucket.s3.us-east-1.amazonaws.com/x']:
            with self.subTest(url=url),self.assertRaises(ControlError):download_config(url,'eu-north-1')
        from .worker_image import NoRedirect
        self.assertIsNone(NoRedirect().redirect_request(None,None,None,None,None,None))

    def test_book_source_requires_contract_but_legacy_rollback_does_not(self):
        with tempfile.TemporaryDirectory() as temp:
            jobs=Jobs(ROOT,Configuration(temp));jobs.update=Mock();aws=Mock()
            source=Path(temp)/'source';source.mkdir()
            jobs.check_worker_image('operation',aws,CONFIG,source);aws.require_book_worker.assert_not_called()
            book=source/'backend/book_alignment/api.py';book.parent.mkdir(parents=True);book.write_text('')
            aws.require_book_worker.side_effect=ControlError('old image')
            with self.assertRaises(ControlError):jobs.check_worker_image('operation',aws,CONFIG,source)
            jobs.update.assert_not_called()
            aws.require_book_worker.side_effect=None;aws.require_book_worker.return_value={'contracts':['book-queue-v1']}
            jobs.check_worker_image('operation',aws,CONFIG,source)
            jobs.update.assert_called_once_with('operation',worker_image={'contracts':['book-queue-v1']})


class OpenAPITests(unittest.TestCase):
    def test_vendored_assets_match_provenance_and_disable_external_validation(self):
        root=ROOT/'tools/cloud_control/web/vendor/swagger-ui'
        provenance=json.loads((root/'provenance.json').read_text())
        self.assertEqual(provenance['version'],'5.35.0')
        for name,expected in provenance['files'].items():
            self.assertEqual(hashlib.sha256((root/name).read_bytes()).hexdigest(),expected)
        script=(ROOT/'tools/cloud_control/web/swagger.js').read_text()
        self.assertIn('validatorUrl:null',script);self.assertIn('persistAuthorization:false',script)

    def test_live_routes_only_and_usable_translation_example(self):
        spec=specification(DISCOVERY,ROUTES)
        self.assertEqual(spec['servers'][0]['url'],API)
        self.assertNotIn('/v1/alignments',spec['paths'])
        from backend.translation.contract import validate_input
        body=spec['paths']['/v1/context-analyses']['post']['requestBody']['content']['application/json']['example']
        validate_input('context',body)

    def test_scoped_path_parameters_forward_500_once(self):
        call=Mock(return_value=(500,{'error':{'code':'FAILED'}},3))
        code,value=manual(CONFIG,DISCOVERY,ROUTES,{'method':'GET','path':'/v1/requests/abc?x=1',
            'use_saved_token':False},call=call)
        self.assertEqual(code,500);call.assert_called_once_with(API,'/v1/requests/abc?x=1','GET',None,None,None)
        for path in ['https://evil.test/v1/me','//evil.test/v1/me','/v1/../me','/v1/requests/%2e%2e','/missing']:
            with self.subTest(path=path),self.assertRaises(ControlError): manual(CONFIG,DISCOVERY,ROUTES,{'method':'GET','path':path},call=call)
        self.assertEqual(call.call_count,1)

    def test_saved_explicit_and_absent_auth_without_retries(self):
        call=Mock(return_value=(200,{},1))
        with tempfile.TemporaryDirectory() as temp:
            token=Path(temp)/'token';token.write_text('x'*30);token.chmod(0o600)
            config={**CONFIG,'access_token_file':str(token)}
            for fields,expected in [({},'x'*30),({'use_saved_token':False},None),({'authorization':'Bearer explicit'},'explicit')]:
                manual(config,DISCOVERY,ROUTES,{'method':'GET','path':'/v1/me',**fields},call=call)
                self.assertEqual(call.call_args.args[4],expected)
            call.side_effect=TimeoutError()
            with self.assertRaises(TimeoutError): manual(config,DISCOVERY,ROUTES,{'method':'GET','path':'/v1/me'},call=call)
            self.assertEqual(call.call_count,4)


class DeploymentTests(unittest.TestCase):
    def test_exact_changes_include_outputs_and_retained_removals(self):
        before={'Resources':{'Keep':{'Type':'AWS::S3::Bucket','DeletionPolicy':'Retain'},'Update':{'Type':'AWS::Lambda::Function','Properties':{'Code':'old'}}},'Outputs':{'Old':{'Value':'a'}}}
        after={'Resources':{'Update':{'Type':'AWS::Lambda::Function','Properties':{'Code':'new'}},'Add':{'Type':'AWS::SQS::Queue'}},'Outputs':{'New':{'Value':'b'}}}
        changes=template_changes(before,after,'stack')
        self.assertEqual({(c['logical_id'],c['action']) for c in changes},{('Keep','remove'),('Update','modify'),('Add','add'),('Outputs.Old','remove'),('Outputs.New','add')})
        self.assertEqual(next(c for c in changes if c['logical_id']=='Update')['changed_fields'],['Code'])
        self.assertTrue(next(c for c in changes if c['logical_id']=='Keep')['retained'])

    def test_prepared_template_cannot_escape_assembly(self):
        with tempfile.TemporaryDirectory() as temp,self.assertRaises(ControlError):
            prepared_changes(Mock(),temp,{'x':{'properties':{'templateFile':'../../outside'}}},[])

    def test_candidates_and_missing_book_components_do_not_claim_deployment(self):
        releases=Mock(); releases.list.return_value=[{'tag':'v0.0.1-backend.999','sha':'a'*40,'operator_supported':True}]
        releases.git.side_effect=lambda *args:'backend/book_alignment/api.py' if args[0]=='ls-tree' else 'backend/book_alignment/api.py'
        result=summary(releases,CONFIG,DISCOVERY,[])
        self.assertTrue(all(not r['deployed'] for r in result['book_components']))
        self.assertTrue(any('consumer' in note for note in result['notes']));self.assertIsNone(result['plan'])

    def test_expired_changed_config_and_changed_baseline_invalidate_plan(self):
        releases=Mock();releases.list.return_value=[{'tag':'v0.0.1-backend.999','sha':'a'*40,'operator_supported':True}]
        releases.git.return_value=''
        plan={'id':'a'*32,'action':'prepare','state':'ready','account_id':ACCOUNT,'region':'eu-north-1',
              'tag':'v0.0.1-backend.999','prepared_at':10000,'config_hash':digest(CONFIG),'baseline':DISCOVERY['stacks']}
        self.assertTrue(summary(releases,CONFIG,DISCOVERY,[plan],now=10001)['plan']['valid'])
        for changed in [{'prepared_at':1},{'config_hash':'changed'},{'baseline':[]},{'region':'us-east-1'}]:
            with self.subTest(changed=changed):
                self.assertFalse(summary(releases,CONFIG,DISCOVERY,[{**plan,**changed}],now=10001)['plan']['valid'])


class DiagnosticHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.app=Application(ROOT,self.tmp.name);self.app.configuration.save(CONFIG)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.server.app=self.app
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)
        self.origin=f'http://127.0.0.1:{self.server.server_port}'

    def request(self,method,path,body=None,headers=None):
        connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port)
        connection.request(method,path,body,headers or {});response=connection.getresponse()
        code=response.status;raw=response.read();head=dict(response.getheaders());connection.close();return code,raw,head

    def test_local_swagger_and_read_guard(self):
        code,raw,head=self.request('GET','/swagger')
        self.assertEqual(code,200);self.assertIn(b'/vendor/swagger-ui/swagger-ui-bundle.js',raw)
        self.assertNotIn('unsafe-eval',head['Content-Security-Policy'])
        self.app.read=Mock(return_value={'available':True,'files':[]})
        self.assertEqual(self.request('GET','/api/storage')[0],403)
        self.assertEqual(self.request('GET','/api/storage',headers={'X-Control-Token':self.app.token})[0],200)

    def test_relay_requires_origin_and_token_and_forwards_error(self):
        self.app.api_description=Mock(return_value=(CONFIG,DISCOVERY,ROUTES))
        payload=json.dumps({'method':'GET','path':'/v1/me','use_saved_token':False})
        self.assertEqual(self.request('POST','/api/manual-request',payload,{'Content-Type':'application/json'})[0],403)
        with patch('tools.cloud_control.server.openapi.manual',return_value=(500,{'error':'upstream'})) as call:
            code,raw,_=self.request('POST','/api/manual-request',payload,{'Content-Type':'application/json',
                'Origin':self.origin,'X-Control-Token':self.app.token})
            self.assertEqual(code,500);self.assertEqual(json.loads(raw),{'error':'upstream'});call.assert_called_once()

    def test_read_and_manual_failures_show_safe_codes_without_leaking_details(self):
        self.app.api_description=Mock(side_effect=RuntimeError('private-credential-detail'))
        code,raw,_=self.request('GET','/api/openapi')
        self.assertEqual(code,400);self.assertIn('RuntimeError',raw.decode())
        code,raw,_=self.request('POST','/api/manual-request',json.dumps({'method':'GET','path':'/v1/me'}),
            {'Content-Type':'application/json','Origin':self.origin,'X-Control-Token':self.app.token})
        self.assertEqual(code,400);self.assertIn('RuntimeError',raw.decode())
        self.assertNotIn('private-credential-detail',raw.decode())


if __name__ == '__main__': unittest.main()
