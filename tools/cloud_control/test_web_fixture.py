"""Offline browser fixture. Run: python -m tools.cloud_control.test_web_fixture --port 8770."""
import argparse
import copy
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import time
from unittest.mock import Mock
from . import openapi
from .config import ControlError, digest
from .deployment import summary
from .server import Application, Handler
from .test_observability import CONFIG, DISCOVERY, ROOT


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--port',type=int,default=8770)
    args=parser.parse_args();now=int(time.time());tag='v0.0.1-backend.999';identifier='a'*32
    changes=[{'stack':'ForeignLanguageLearnerOperatorAlignment-prod','logical_id':'BooksQueue','type':'AWS::SQS::Queue',
              'action':'add','changed_fields':[],'review':False}]
    plan={'id':identifier,'action':'prepare','state':'ready','account_id':CONFIG['account_id'],'region':'eu-north-1',
          'tag':tag,'prepared_at':now,'created_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(now)),
          'config_hash':digest(CONFIG),'baseline':DISCOVERY['stacks'],'resource_changes':changes,'sha':'a'*40,'log':'OFFLINE FIXTURE'}
    release={'tag':tag,'sha':'a'*40,'operator_supported':True}
    releases=Mock();releases.list.return_value=[release];releases.git.return_value='backend/book_alignment/api.py'
    routes=[{'RouteKey':'GET /v1/health','AuthorizationType':'JWT'}, {'RouteKey':'GET /v1/error','AuthorizationType':'JWT'}]
    buckets=[{'id':'fixture-books','logical_id':'BooksArtifacts','type':'AWS::S3::Bucket','stack':'ForeignLanguageLearnerOperatorAlignment-prod'}]
    group={'id':'fixture-api-log','logical_id':'AccessLogs','type':'AWS::Logs::LogGroup','stack':'ForeignLanguageLearnerOperator-prod'}
    checked=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(now))
    def read(kind,params):
        if kind=='deployment':return {'available':True,**summary(releases,CONFIG,DISCOVERY,[plan],tag=params.get('tag'))}
        data={
            'storage':{'buckets':buckets,'bucket':buckets[0],'files':[{'key':'books/'+('second' if params.get('cursor') else 'first')+'.zip','bytes':12345678,'modified_at':checked,'storage_class':'STANDARD'}],
                       'cursor':None if params.get('cursor') else 'next','scope':'OFFLINE FIXTURE · текущая страница'},
            'costs':{'start':'2026-11-01','end_exclusive':'2026-11-15','total':'0.30','currency':'USD','estimated':True,
                     'services':[{'name':'TEST Amazon S3','amount':'0.10'},{'name':'TEST ECS','amount':'0.20'}],
                     'daily':[{'date':'2026-11-12','amount':'0.10'},{'date':'2026-11-13','amount':'0.20'}],
                     'scope':'OFFLINE FIXTURE · не реальные расходы','note':'Тест отображения',
                     'plan':{'type':'FREE','status':'TEST','remaining_credits':'10','currency':'USD'}},
            'alignment':{'days':int(params.get('days',30)),'sources':[{'table':'fixture','complete':True}], 'complete':True,
                'requests':1,'executions':2,'input_bytes':1000000,'mean_runtime_seconds':120,'p95_runtime_seconds':120,'duration_samples':1,
                'scope':'OFFLINE FIXTURE · сохранённые задачи','duration_note':'Тест времени', 'jobs':[{
                'job_id':'fixture-job','title':'TEST book','created_at':now-300,'status':'succeeded','input_kind':'ZIP',
                'input_bytes':1000000,'attempts':2,'queue_seconds':30,'runtime_seconds':120}]},
            'errors':{'hours':int(params.get('hours',24)),'metrics':[{'api_id':'fixture','requests':10,'errors_5xx':1}],
                'groups':[group],'group':group,'cursor':None,'scope':'OFFLINE FIXTURE · тест ошибки',
                'events':[{'id':'test-error','timestamp':now*1000,'stream':'test-stream','message':'{"status":"500","requestId":"TEST-REQUEST"}'}]},
        }[kind]
        return {'available':True,'warnings':[],'checked_at':checked,**data}
    class FixtureHandler(Handler):
        def send(self,status,body,content_type='application/json; charset=utf-8',**kwargs):
            if isinstance(body,bytes) and content_type.startswith('text/html'):
                body=body.replace(b'PRODUCTION',b'OFFLINE TEST').replace('Состояние продакшена'.encode(),'Тестовые данные'.encode())
            super().send(status,body,content_type,**kwargs)
    with tempfile.TemporaryDirectory() as directory:
        app=Application(ROOT,Path(directory));app.configuration.save(copy.deepcopy(CONFIG))
        app.jobs.releases=releases;app.jobs.list=lambda:[plan];app.read=read
        app.status=lambda:{'configured':True,'account_id':CONFIG['account_id'],'region':'eu-north-1','stacks':DISCOVERY['stacks'],'alarms':[],'checked_at':checked}
        app.api_description=lambda:(CONFIG,DISCOVERY,routes)
        def blocked(*_):raise ControlError('Offline fixture: операции AWS отключены.')
        app.jobs.start=blocked
        original=openapi.manual
        openapi.manual=lambda config,discovery,known,value:original(config,discovery,known,value,
            call=lambda base,path,*_: (500 if path=='/v1/error' else 200, {'status':'fixture_ok' if path=='/v1/health' else 'fixture_error'},1))
        server=ThreadingHTTPServer(('127.0.0.1',args.port),FixtureHandler);server.app=app
        print(f'OFFLINE TEST http://127.0.0.1:{args.port}',flush=True)
        try:server.serve_forever()
        except KeyboardInterrupt:pass
        finally:server.server_close()


if __name__=='__main__':main()
