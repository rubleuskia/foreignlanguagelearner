import copy
import http.client
import json
import os
import subprocess
import tempfile
import tarfile
import io
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer
from .aws import AWS, api_url, deployable
from .config import Configuration, ControlError, digest, validate, deployment_context, expected_stacks, validate_benchmark
from .health import run
from .jobs import Jobs, atomic_json, tree_digest
from .releases import Releases, parse_tag
from .server import Application, Handler

ROOT = Path(__file__).resolve().parents[2]
SHA = 'a' * 40
TAG = 'backend-123-' + SHA[:12]
CONFIG = {'account_id':'123456789012', 'region':'eu-north-1', 'profile':'fll-prod', 'context':{}}
SNAPSHOT = [{'name':'ForeignLanguageLearnerCloudFoundation-prod', 'status':'UPDATE_COMPLETE',
    'outputs':{'ApiUrl':'https://test.execute-api.eu-north-1.amazonaws.com'}, 'tags':{}}]


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = Configuration(self.tmp.name)
        self.config.save(copy.deepcopy(CONFIG))

    def token_config(self):
        path=Path(self.tmp.name)/'token'
        path.write_text('test-access-token-not-an-actual-jwt');path.chmod(0o600)
        return {**CONFIG,'access_token_file':str(path)}

    def test_config_refuses_email_unknown_secret_fields_wrong_region_and_secret_contents(self):
        for value in [{**CONFIG,'account_id':'sweexxik@gmail.com'}, {**CONFIG,'secret_access_key':'secret'},
                      {**CONFIG,'region':'us-east-1'}, {**CONFIG,'region':'eu-central-1'},
                      {**CONFIG,'context':{'openaiSecretArn':'arn:aws:secretsmanager:eu-central-1:123456789012:secret:provider-AbCdEf'}},
                      {**CONFIG,'context':{'openaiSecretArn':'sk-example'}}]:
            with self.subTest(value=value), self.assertRaises(ControlError): validate(value)
        self.assertEqual(self.config.path.stat().st_mode & 0o777, 0o600)

    def test_wrong_aws_account_blocks_snapshot_before_read(self):
        aws=AWS.__new__(AWS);aws.config=CONFIG
        sts=Mock();sts.get_caller_identity.return_value={'Account':'999999999999'}
        aws.client=Mock(return_value=sts)
        with self.assertRaises(ControlError): aws.snapshot()
        aws.client.assert_called_once_with('sts')

    def test_prepare_with_view_only_config_reports_missing_deployment_fields(self):
        self.config.save({k:v for k,v in CONFIG.items() if k != 'context'})
        aws_factory=Mock(); releases=Mock()
        jobs=Jobs(ROOT,self.config,aws_factory=aws_factory,releases=releases)
        result=self.wait(jobs,jobs.start('prepare',{'tag':TAG})['id'])
        self.assertEqual(result['state'],'failed')
        self.assertIn('Настройка',result['error'])
        self.assertIn('appleClientId',result['error'])
        self.assertIn('openaiSecretArn',result['error'])
        self.assertNotIn('KeyError',result['error'])
        aws_factory.assert_not_called(); releases.verify.assert_not_called()

    def test_operator_context_requires_no_apple_and_audio_requires_real_artifacts(self):
        config={**CONFIG,'deployment_mode':'operator','context':{'operatorAlignment':'false'}}
        context=deployment_context(config)
        self.assertEqual(context['operatorUsername'],'operator')
        self.assertEqual(expected_stacks(config),['ForeignLanguageLearnerOperator-prod'])
        self.assertNotIn('appleClientId',context)
        for extra in [{}, {'workerRepositoryName':'worker'},
                      {'workerRepositoryName':'worker','workerImageDigest':'sha256:'+'a'*64}]:
            with self.assertRaises(ControlError):
                deployment_context({**config,'context':{'operatorAlignment':'true',**extra}})
        for limit in ['0','1001','-1','1.5']:
            with self.assertRaises(ControlError): deployment_context({**config,'context':{'dailyModelLimit':limit}})

    def test_benchmark_rejects_unmatched_image_missing_languages_and_nonfinite_metrics(self):
        digest_value='sha256:'+'a'*64
        good={'workerImageDigest':digest_value,'maxJobCostUsd':1,'languages':{
            language:{'qualityAccepted':True,'runtimeSeconds':300,'peakMemoryMiB':1024,'costUsd':0.1}
            for language in ('en','fr','es','de','it','pl')}}
        validate_benchmark(good,digest_value)
        for changed in [{'workerImageDigest':'wrong'},{'languages':{}},{'maxJobCostUsd':float('nan')}]:
            with self.assertRaises(ControlError): validate_benchmark({**good,**changed},digest_value)

    def test_polish_pilot_report_requires_measured_scope_and_three_full_length_runs(self):
        image='sha256:'+'a'*64
        row={'qualityAccepted':True,'runtimeSeconds':300,'peakMemoryMiB':1024,
             'costUsd':0.1,'audioSeconds':300,'runs':3}
        report={'workerImageDigest':image,'scope':'operator-pl-300-v1','maxAudioSeconds':300,
                'maxJobCostUsd':1,'languages':{'pl':row}}
        validate_benchmark(report,image,operator=True)
        with self.assertRaises(ControlError): validate_benchmark(report,image)
        for changed in [{'qualityAccepted':False},{'audioSeconds':299},{'runs':2},
                        {'runtimeSeconds':float('nan')},{'peakMemoryMiB':8193}]:
            with self.subTest(changed=changed), self.assertRaises(ControlError):
                validate_benchmark({**report,'languages':{'pl':{**row,**changed}}},image,operator=True)
        for changed in [{'scope':'other'},{'maxAudioSeconds':3600},{'workerImageDigest':'wrong'}]:
            with self.assertRaises(ControlError): validate_benchmark({**report,**changed},image,operator=True)

    def test_operator_prepare_uses_verified_source_and_operator_builder_without_apple(self):
        self.config.save({**CONFIG,'deployment_mode':'operator','context':{'operatorAlignment':'false'}})
        aws=Mock();aws.snapshot.return_value=[]
        release=Mock();release.verify.return_value={'tag':TAG,'sha':SHA,'ci_url':'https://github.com/test'}
        jobs=Jobs(ROOT,self.config,aws_factory=lambda c:aws,releases=release)
        commands=[]
        def execute(key,argv,**kwargs):
            commands.append(argv)
            if argv[:2]==['git','archive']:
                with tarfile.open(argv[4],'w') as bundle:
                    for name in ['scripts/build-cloud.py','infra/alignment/bin/cloud.ts','infra/alignment/bin/operator.ts']:
                        info=tarfile.TarInfo(name);info.size=1;bundle.addfile(info,io.BytesIO(b'x'))
            if 'synth' in argv:
                area=jobs.plans/key/'assembly';area.mkdir()
                (area/'template.json').write_text(json.dumps({'Resources':{}}))
                (area/'manifest.json').write_text(json.dumps({'artifacts':{'Operator':{
                    'type':'aws:cloudformation:stack','environment':'aws://123456789012/eu-north-1',
                    'properties':{'stackName':'ForeignLanguageLearnerOperator-prod','templateFile':'template.json'}}}}))
        jobs.execute=execute
        result=self.wait(jobs,jobs.start('prepare',{'tag':TAG})['id'])
        self.assertEqual(result['state'],'ready',result.get('error'))
        release.verify.assert_called_once_with(TAG)
        build=next(c for c in commands if '--output' in c and 'scripts/build-cloud.py' in c[1])
        self.assertIn('operator',build);self.assertNotIn('--apple-roots',build)
        synth=next(c for c in commands if 'synth' in c)
        self.assertIn('node_modules/.bin/ts-node bin/operator.ts',synth)
        self.assertFalse(any('deploy' in c for c in commands))

    def test_operator_smoke_uses_operator_profile_without_subscription_routes(self):
        config={**self.token_config(),'deployment_mode':'operator','context':{'operatorAlignment':'false'}}
        snapshot=[{**SNAPSHOT[0],'name':'ForeignLanguageLearnerOperator-prod'}]
        paths=[]
        def call(base,path,method='GET',body=None,token=None,key=None):
            paths.append(path)
            if path.startswith('/control-nonexistent-'): return 404,{},1
            if not token: return 401,{},1
            if path=='/v1/me': return 200,{'schema_version':1,'user_id':'operator','role':'operator'},1
            if path=='/v1/health': return 200,{'status':'ok'},1
            return (400 if path=='/v1/context-analyses' else 404),{},1
        report=run(config,snapshot,call=call)
        self.assertEqual(report['state'],'passed')
        self.assertNotIn('/v1/me/entitlements',paths);self.assertNotIn('/v1/products',paths)

    def test_busy_failed_stack_and_non_aws_endpoint_are_blocked(self):
        for status in ['UPDATE_IN_PROGRESS','ROLLBACK_FAILED','DELETE_COMPLETE']:
            with self.assertRaises(ControlError): deployable([{**SNAPSHOT[0],'status':status}])
        for url in ['http://localhost/','https://evil.example','https://x.execute-api.eu-north-1.amazonaws.com@evil.example',
                    'https://x.execute-api.eu-north-1.amazonaws.com?token=value',
                    'https://x.execute-api.eu-central-1.amazonaws.com']:
            with self.assertRaises(ControlError): api_url([{**SNAPSHOT[0],'outputs':{'ApiUrl':url}}])

    def test_failed_or_foreign_ci_cannot_authorize_tag(self):
        releases=Releases(ROOT)
        releases.refresh=Mock()
        releases.git=Mock(side_effect=lambda *a: 'tag' if a[0]=='cat-file' else SHA if a[0]=='rev-parse' else '')
        good={'run_number':123,'head_sha':SHA,'head_branch':'main','event':'push','conclusion':'success','html_url':'https://github.com/test'}
        for changed in [{'conclusion':'failure'},{'head_branch':'other'},{'event':'pull_request'},{'run_number':124},{'head_sha':'b'*40}]:
            with patch('tools.cloud_control.releases.command',return_value=json.dumps({'workflow_runs':[{**good,**changed}]})):
                with self.assertRaises(ControlError): releases.verify(TAG)
        with patch('tools.cloud_control.releases.command',return_value=json.dumps({'workflow_runs':[good]})):
            self.assertEqual(releases.verify(TAG)['sha'],SHA)
        for bad in ['main','--all','backend-1-$(touch /tmp/oops)','backend-123-'+('b'*12)]:
            with self.assertRaises(ControlError): releases.verify(bad)

    def plan(self, jobs):
        key='a'*32
        area=jobs.plans/key;area.mkdir()
        (area/'assembly').mkdir();(area/'assembly/test.json').write_text('{}')
        plan={'id':key,'action':'prepare','state':'ready','tag':TAG,'sha':SHA,'created_at':'2026-11-01',
            'prepared_at':time.time(),'config_hash':digest(CONFIG),'artifact_hash':tree_digest(area),'baseline':SNAPSHOT}
        atomic_json(jobs.directory/(key+'.json'),plan)
        return plan,{'plan_id':key,'confirm':CONFIG['account_id']+'/'+TAG}

    def wait(self,jobs,key):
        deadline=time.monotonic()+5
        while jobs.active and time.monotonic()<deadline: time.sleep(.01)
        self.assertIsNone(jobs.active)
        return jobs.get(key)

    def test_stale_changed_consumed_and_tampered_plans_block_deploy(self):
        jobs=Jobs(ROOT,self.config)
        plan,body=self.plan(jobs)
        jobs.validate_plan(plan,CONFIG,body)
        for changed in [{'prepared_at':time.time()-3601},{'config_hash':'changed'},{'state':'consumed'}]:
            with self.subTest(changed=changed), self.assertRaises(ControlError):
                jobs.validate_plan({**plan,**changed},CONFIG,body)
        with self.assertRaises(ControlError): jobs.validate_plan(plan,CONFIG,{**body,'confirm':'wrong'})
        (jobs.plans/plan['id']/'assembly/test.json').write_text('tampered')
        with self.assertRaises(ControlError): jobs.validate_plan(plan,CONFIG,body)

    def test_changed_prod_blocks_before_any_deploy_command(self):
        aws=Mock();aws.snapshot.return_value=[{**SNAPSHOT[0],'updated_at':'changed'}]
        release=Mock();release.verify.return_value={'sha':SHA}
        jobs=Jobs(ROOT,self.config,aws_factory=lambda c:aws,releases=release)
        plan,body=self.plan(jobs)
        jobs.execute=Mock()
        result=self.wait(jobs,jobs.start('deploy',body)['id'])
        self.assertEqual(result['state'],'failed');jobs.execute.assert_not_called()
        self.assertEqual(jobs.get(plan['id'])['state'],'ready')

    def test_deploy_uses_prepared_assembly_marks_consumed_and_runs_only_smoke(self):
        aws=Mock();aws.snapshot.return_value=copy.deepcopy(SNAPSHOT)
        release=Mock();release.verify.return_value={'sha':SHA}
        jobs=Jobs(ROOT,self.config,aws_factory=lambda c:aws,releases=release)
        plan,body=self.plan(jobs);jobs.execute=Mock()
        with patch('tools.cloud_control.jobs.health.run',return_value={'state':'warning','cases':[]}) as health:
            result=self.wait(jobs,jobs.start('deploy',body)['id'])
        argv=jobs.execute.call_args.args[1]
        self.assertIn(str(jobs.plans/plan['id']/'assembly'),argv)
        self.assertIn('deploy',argv);self.assertIn('--rollback',argv)
        self.assertNotIn('synth',argv);self.assertTrue(result['deployed'])
        self.assertEqual(result['state'],'warning');self.assertEqual(jobs.get(plan['id'])['state'],'consumed')
        self.assertNotIn('inference',str(health.call_args))
        with self.assertRaises(ControlError): jobs.start('deploy',body)

    def test_jobs_serialize_and_restart_never_retries_interrupted_deploy(self):
        jobs=Jobs(ROOT,self.config)
        jobs.lock.acquire()
        with self.assertRaises(ControlError): jobs.start('refresh',{})
        jobs.lock.release()
        atomic_json(jobs.directory/('c'*32+'.json'),{'id':'c'*32,'action':'deploy','state':'running','created_at':'2026'})
        restarted=Jobs(ROOT,self.config)
        self.assertEqual(restarted.get('c'*32)['state'],'interrupted')
        self.assertIsNone(restarted.active)

    def test_remaining_child_blocks_restart_until_process_exits(self):
        jobs=Jobs(ROOT,self.config)
        atomic_json(jobs.directory/('c'*32+'.json'),{'id':'c'*32,'action':'deploy','state':'running','created_at':'2026','child_pid':os.getpid()})
        restarted=Jobs(ROOT,self.config)
        with self.assertRaises(ControlError): restarted.start('refresh',{})

    def test_public_smoke_does_not_claim_authenticated_coverage(self):
        seen=[]
        def call(base,path,method='GET',body=None,token=None,key=None):
            seen.append((method,path,token))
            return (404 if path.startswith('/control-') else 401),{},4
        report=run(CONFIG,SNAPSHOT,call=call)
        self.assertEqual(report['state'],'warning');self.assertEqual(report['coverage'],'public')
        self.assertTrue(any(c['state']=='skipped' for c in report['cases']))
        self.assertFalse(any(token for _,_,token in seen))

    def test_public_route_accidentally_unprotected_fails_smoke(self):
        report=run(CONFIG,SNAPSHOT,call=lambda *a,**kw:(200,{},2))
        self.assertEqual(report['state'],'failed')

    def test_token_file_permissions_and_missing_inference_confirmation(self):
        config=self.token_config();Path(config['access_token_file']).chmod(0o644)
        with self.assertRaises(ControlError): run(config,SNAPSHOT,call=Mock())
        jobs=Jobs(ROOT,self.config)
        with self.assertRaises(ControlError): jobs.start('tests',{'mode':'inference','confirm':'no'})

    def test_inference_recovers_lost_post_with_one_key_and_validates_both_results(self):
        config=self.token_config();records=[];submitted={};lost=[False];keys=[]
        context_result={'phrase_translation':'дом','word_explanations':[{'source_word':'dom','lemma':'dom','meaning':'дом'}]}
        word_result={'definition':'Дом — место для жизни.','meaningInContext':'дом','examples':[{'phrase':'To mój dom.','translation':'Это мой дом.'}]}
        def call(base,path,method='GET',body=None,token=None,key=None):
            if token is None:return (404 if path.startswith('/control-') else 401),{},1
            if method=='POST' and body=={}:return 400,{'error':{'code':'INVALID_REQUEST'}},1
            if path=='/v1/me': return 200,{'schema_version':1,'user_id':'user','app_account_token':'uuid'},1
            if path.endswith('entitlements'):return 200,{'schema_version':1,'features':{},'allowance':{}},1
            if path=='/v1/products':return 200,{'schema_version':1,'products':[],'purchases_enabled':False},1
            if method=='POST':
                self.assertTrue(any(r['requests'] and r['requests'][-1]['key']==key for r in records))
                kind='context' if 'context-analyses' in path else 'word'
                value={'request_id':key,'state':'succeeded','result':context_result if kind=='context' else word_result}
                submitted[key]=value;keys.append(key)
                if not lost[0]:lost[0]=True;raise TimeoutError()
                return 202,value,1
            if '/by-key/' in path:
                item=submitted.get(path.rsplit('/',1)[-1]);return (200,item,1) if item else (404,{},1)
            if path.startswith('/v1/requests/'):
                return 200,submitted[path.rsplit('/',1)[-1]],1
            raise AssertionError(path)
        report=run(config,SNAPSHOT,'inference',call=call,checkpoint=lambda r:records.append(copy.deepcopy(r)))
        self.assertEqual(report['state'],'passed');self.assertEqual(report['coverage'],'inference')
        self.assertEqual(len(set(keys)),2);self.assertEqual(len(keys),4)
        self.assertNotIn('test-access-token',json.dumps(report))

    def test_failed_preflight_never_spends_inference(self):
        config=self.token_config();seen=[]
        def call(*args,**kwargs):seen.append((args,kwargs));return 503,{},2
        report=run(config,SNAPSHOT,'inference',call=call)
        self.assertEqual(report['state'],'failed');self.assertEqual(report['requests'],[])
        self.assertFalse(any(len(args)>5 and args[5] for args,kw in seen))

    def test_redacts_jwt_and_aws_key_from_subprocess_journal(self):
        jobs=Jobs(ROOT,self.config)
        atomic_json(jobs.directory/('c'*32+'.json'),{'id':'c'*32,'state':'running','log':'','created_at':'2026'})
        jobs.log('c'*32,'eyJhbGciOi.xxxxxx.yyyyyy AKIA'+'A'*16)
        output=jobs.get('c'*32)['log']
        self.assertNotIn('eyJhbGciOi',output);self.assertNotIn('AKIA',output)

    def test_prepare_freezes_inputs_and_checks_assembly_environment_and_routes(self):
        from .config import expected_stacks
        config={**CONFIG,'context':{'appleClientId':'client','appleTeamId':'team','appleSignInKeyId':'key',
            'appleSignInSecretArn':'arn:aws:secretsmanager:eu-north-1:123456789012:secret:login-AbCdEf',
            'appleApiSecretArn':'arn:aws:secretsmanager:eu-north-1:123456789012:secret:store-AbCdEf',
            'openaiSecretArn':'arn:aws:secretsmanager:eu-north-1:123456789012:secret:provider-AbCdEf',
            'callbackUrl':'fll://auth','loginDomainPrefix':'test-prod','appleProducts':'test','appAppleId':'123'}}
        roots=Path(self.tmp.name)/'input-roots';roots.mkdir();(roots/'root.cer').write_bytes(b'root-fixture')
        policy=Path(self.tmp.name)/'input-policy.json';policy.write_text('{"version":"fixture"}')
        config.update(apple_roots=str(roots),root_sha256=['a'*64],policy_file=str(policy))
        self.config.save(config)
        aws=Mock();aws.snapshot.return_value=copy.deepcopy(SNAPSHOT)
        releases=Mock();releases.verify.return_value={'tag':TAG,'sha':SHA,'ci_url':'https://github.com/test'}
        jobs=Jobs(ROOT,self.config,aws_factory=lambda c:aws,releases=releases)
        mode=['good'];calls=[]
        def execute(key,argv,**kwargs):
            calls.append(argv)
            if argv[0]=='git':
                archive=Path(argv[argv.index('--output')+1])
                with tarfile.open(archive,'w') as bundle:
                    for file in ['scripts/build-cloud.py','infra/alignment/bin/cloud.ts']:
                        info=tarfile.TarInfo(file);info.size=1;bundle.addfile(info,io.BytesIO(b'x'))
            elif 'synth' in argv:
                assembly=Path(argv[argv.index('--output')+1]);assembly.mkdir()
                artifacts={}
                for index,name in enumerate(expected_stacks(config)):
                    file=f'{index}.template.json'
                    template={'Resources':{'Route':{'Type':'AWS::ApiGatewayV2::Route','Properties':
                        {'RouteKey':'GET /v1/me','AuthorizationType':'NONE' if mode[0]=='public' else 'JWT'}}}}
                    (assembly/file).write_text(json.dumps(template))
                    artifacts[name]={'type':'aws:cloudformation:stack',
                        'environment':'aws://999999999999/eu-north-1' if mode[0]=='foreign' else 'aws://123456789012/eu-north-1',
                        'properties':{'stackName':name,'templateFile':file}}
                (assembly/'manifest.json').write_text(json.dumps({'artifacts':artifacts}))
        jobs.execute=Mock(side_effect=execute)
        for variation in ['foreign','public','good']:
            mode[0]=variation
            result=self.wait(jobs,jobs.start('prepare',{'tag':TAG})['id'])
            self.assertEqual(result['state'],'ready' if variation=='good' else 'failed')
        self.assertEqual((jobs.plans/result['id']/'policy.json').read_text(),policy.read_text())
        self.assertTrue(any('synth' in call and '--lookups=false' in call for call in calls))
        self.assertTrue(any('diff' in call and '--no-change-set' in call for call in calls))
        self.assertFalse(any('deploy' in call for call in calls))
        policy.write_text('operator file changed after preparation')
        jobs.validate_plan(result,config,{'confirm':CONFIG['account_id']+'/'+TAG})

    def test_execute_saves_sanitized_output_and_stops_failed_command(self):
        jobs=Jobs(ROOT,self.config);key='c'*32
        atomic_json(jobs.directory/(key+'.json'),{'id':key,'state':'running','log':'','created_at':'2026'})
        with self.assertRaises(ControlError):
            jobs.execute(key,['python3','-c','print("fixture failure"); raise SystemExit(3)'],cwd=ROOT)
        self.assertIn('fixture failure',jobs.get(key)['log'])
        self.assertIsNone(jobs.get(key)['child_pid'])
        self.assertFalse(list(jobs.directory.glob('*.output')))


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.app=Application(ROOT,self.tmp.name)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.server.app=self.app
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)

    def req(self,path='/',method='GET',body=None,headers=None):
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        conn.request(method,path,body=body,headers=headers or {})
        response=conn.getresponse();result=response.status,response.read(),dict(response.getheaders());conn.close();return result

    def test_html_csp_and_rebinding_host_guard(self):
        code,body,headers=self.req()
        self.assertEqual(code,200);self.assertIn(self.app.token.encode(),body)
        self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        self.assertEqual(self.req(headers={'Host':'evil.example'})[0],403)
        self.assertEqual(self.req('/../../config.json')[0],404)

    def test_mutation_requires_both_exact_origin_and_csrf(self):
        headers={'Content-Type':'application/json','Origin':f'http://127.0.0.1:{self.server.server_port}'}
        self.assertEqual(self.req('/api/config','POST',json.dumps(CONFIG),headers)[0],403)
        headers['X-Control-Token']=self.app.token
        self.assertEqual(self.req('/api/config','POST',json.dumps(CONFIG),headers)[0],200)
        headers['Origin']='https://evil.example'
        self.assertEqual(self.req('/api/config','POST',json.dumps(CONFIG),headers)[0],403)


class TaggingTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        area=Path(self.tmp.name);self.remote=area/'origin.git';self.repo=area/'repo'
        self.env={**os.environ,'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1'}
        self.cmd('git','init','--bare',str(self.remote));self.repo.mkdir();self.cmd('git','init','-b','main')
        (self.repo/'backend').mkdir();(self.repo/'backend/VERSION').write_text('0.0.1\n')
        operator=self.repo/'infra/alignment/bin/operator.ts';operator.parent.mkdir(parents=True);operator.write_text('// fixture')
        self.cmd('git','add','backend/VERSION','infra')
        self.cmd('git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-m','fixture')
        self.sha=self.cmd('git','rev-parse','HEAD').stdout.strip()
        self.cmd('git','remote','add','origin',str(self.remote));self.cmd('git','push','origin','main')
        self.ci_url='https://github.com/rubleuskia/foreignlanguagelearner/actions/runs/456'
        self.env.update(RELEASE_EVENT='push',RELEASE_BRANCH='main',RELEASE_SHA=self.sha,
                        RELEASE_RUN_NUMBER='123',RELEASE_CI_URL=self.ci_url)
        self.tag='v0.0.1-backend.123'

    def cmd(self,*args,check=True):
        return subprocess.run(args,cwd=self.repo if self.repo.exists() else self.repo.parent,
                              env=self.env,capture_output=True,text=True,check=check)

    def tag_script(self,check=True):
        return self.cmd('bash',str(ROOT/'scripts/tag-verified-main.sh'),check=check)

    def metadata(self,run=123,**changes):
        return {'schema_version':1,'version':'0.0.1','commit':self.sha,'ci_run_number':run,
                'ci_url':self.ci_url,**changes}

    def annotate(self,tag,metadata):
        self.cmd('git','-c','user.name=Test','-c','user.email=test@example.invalid',
                 'tag','-a',tag,'-m',json.dumps(metadata))

    def test_tag_creation_is_annotated_immutable_and_idempotent(self):
        self.tag_script();first=self.cmd('git','rev-parse',self.tag).stdout.strip();self.tag_script()
        self.assertEqual(self.cmd('git','rev-parse',self.tag).stdout.strip(),first)
        self.assertEqual(self.cmd('git','rev-parse',self.tag+'^{commit}').stdout.strip(),self.sha)
        self.assertEqual(self.cmd('git','cat-file','-t',self.tag).stdout.strip(),'tag')
        annotation=json.loads(self.cmd('git','for-each-ref','--format=%(contents)','refs/tags/'+self.tag).stdout)
        self.assertEqual(annotation,self.metadata())
        self.assertEqual(self.cmd('git','tag','-l','backend-*').stdout.strip(),'')

    def test_producer_reads_version_from_tested_commit_not_dirty_working_copy(self):
        (self.repo/'backend/VERSION').write_text('99.0.0\n')
        self.tag_script()
        self.assertEqual(self.cmd('git','tag','-l').stdout.strip(),self.tag)

    def test_unverified_events_branches_identity_and_ci_url_cannot_create_tags(self):
        for changes in [{'RELEASE_EVENT':'pull_request'},{'RELEASE_BRANCH':'feature'},
                        {'RELEASE_SHA':'b'*40},{'RELEASE_RUN_NUMBER':'01'},
                        {'RELEASE_CI_URL':'https://evil.example/actions/runs/456'}]:
            with self.subTest(changes=changes):
                old=self.env.copy();self.env.update(changes)
                self.assertNotEqual(self.tag_script(check=False).returncode,0)
                self.assertEqual(self.cmd('git','tag','-l').stdout.strip(),'')
                self.env=old

    def test_existing_lightweight_or_mismatched_annotation_cannot_be_replaced(self):
        for run,annotated in [(124,False),(125,True)]:
            tag='v0.0.1-backend.'+str(run)
            if annotated:self.annotate(tag,self.metadata(run,commit='b'*40))
            else:self.cmd('git','tag',tag)
            self.cmd('git','push','origin',tag)
            before=self.cmd('git','rev-parse',tag).stdout.strip()
            self.env['RELEASE_RUN_NUMBER']=str(run)
            self.assertNotEqual(self.tag_script(check=False).returncode,0)
            self.assertEqual(self.cmd('git','rev-parse',tag).stdout.strip(),before)

    def test_invalid_base_version_is_rejected(self):
        for version in ['01.0.1','0.0.1.extra','0.0.1\n0.0.2']:
            with self.subTest(version=version):
                (self.repo/'backend/VERSION').write_text(version+'\n')
                self.cmd('git','add','backend/VERSION')
                self.cmd('git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-m','invalid version')
                self.env['RELEASE_SHA']=self.cmd('git','rev-parse','HEAD').stdout.strip()
                self.assertNotEqual(self.tag_script(check=False).returncode,0)
                self.assertEqual(self.cmd('git','tag','-l').stdout.strip(),'')

    def test_listing_preserves_legacy_rollbacks_and_operator_capability(self):
        self.tag_script()
        legacy='backend-122-'+self.sha[:12]
        self.cmd('git','-c','user.name=Test','-c','user.email=test@example.invalid',
                 'tag','-a',legacy,'-m','Verified main CI: legacy')
        self.cmd('git','tag','v0.0.1-backend.126')
        self.annotate('v0.0.1-backend.127',self.metadata(127,commit='b'*40))
        self.annotate('v9.9.9-backend.128',self.metadata(128,version='9.9.9'))
        self.annotate('v0.0.1-backend.129',{'schema_version':1})
        releases=Releases(self.repo);listed=releases.list()
        self.assertEqual({r['tag'] for r in listed},{self.tag,legacy})
        self.assertTrue(all(r['operator_supported'] for r in listed))
        self.assertEqual(next(r for r in listed if r['tag']==self.tag)['version'],'0.0.1')
        self.assertTrue(next(r for r in listed if r['tag']==legacy)['legacy'])

    def test_refresh_fetches_version_and_legacy_tags_with_valid_git_refspecs(self):
        self.tag_script()
        legacy='backend-122-'+self.sha[:12]
        self.cmd('git','-c','user.name=Test','-c','user.email=test@example.invalid',
                 'tag','-a',legacy,'-m','Verified main CI: legacy')
        self.cmd('git','push','origin',legacy)
        self.cmd('git','tag','-d',legacy,self.tag)
        releases=Releases(self.repo);original=releases.git
        def git(*args):
            if args==('remote','get-url','origin'): return 'https://github.com/rubleuskia/foreignlanguagelearner.git'
            return original(*args)
        with patch.object(releases,'git',side_effect=git): listed=releases.refresh()
        self.assertEqual({r['tag'] for r in listed},{self.tag,legacy})

    def test_metadata_schema_rejects_boolean_numbers_foreign_urls_and_extra_fields(self):
        releases=Releases(self.repo)
        for changes in [{'schema_version':True},{'ci_run_number':True},{'ci_url':'https://evil.example/'},
                        {'ci_url':123},{'extra':'unexpected'}]:
            with self.subTest(changes=changes):
                releases.git=Mock(return_value=json.dumps(self.metadata(**changes)))
                with self.assertRaises(ControlError):releases.identity(self.tag,self.sha)

    def test_new_version_requires_matching_successful_main_ci_and_annotation_url(self):
        self.tag_script();releases=Releases(self.repo);releases.refresh=Mock()
        good={'run_number':123,'head_sha':self.sha,'head_branch':'main','event':'push',
              'conclusion':'success','html_url':self.ci_url}
        with patch('tools.cloud_control.releases.command',wraps=__import__('tools.cloud_control.releases',fromlist=['command']).command) as command:
            # Git remains real; only the GitHub response is faked.
            original=command._mock_wraps
            def call(argv,**kwargs):
                if argv[0]=='gh':return json.dumps({'workflow_runs':[good]})
                return original(argv,**kwargs)
            command.side_effect=call
            self.assertEqual(releases.verify(self.tag)['sha'],self.sha)
            for change in [{'run_number':124},{'head_sha':'b'*40},{'event':'pull_request'},
                           {'head_branch':'other'},{'conclusion':'failure'},{'html_url':self.ci_url+'7'}]:
                with self.subTest(change=change):
                    rejected={**good,**change}
                    command.side_effect=lambda argv,**kw: json.dumps({'workflow_runs':[rejected]}) if argv[0]=='gh' else original(argv,**kw)
                    with self.assertRaises(ControlError): releases.verify(self.tag)

    def test_version_parser_accepts_semver_core_and_rejects_ambiguous_or_unsafe_refs(self):
        self.assertEqual(parse_tag('v0.0.1-backend.123')['run_number'],123)
        self.assertEqual(parse_tag('v12.3.4-backend.1')['version'],'12.3.4')
        for name in ['v01.0.1-backend.1','v0.0.1-backend.01','v0.0.1.extra.1','v0.0.1-backend.1+build',
                     'v0.0.1-backend.1\n','v0.0.1-backend.1٣','--all',None,'v0.0.1-backend.$(touch /tmp/oops)']:
            with self.subTest(name=name):self.assertIsNone(parse_tag(name))


if __name__=='__main__':unittest.main()
