"""Persistent exam imports, student delivery, optimistic attempts and grading."""
from __future__ import annotations

import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import time
import uuid

from backend.translation.contract import inference_settings
from .assessment_contract import build_grading_request, compile_assessment, validate_assessment_result
from .contract import (ExamError, ACTIVE_SECTIONS, PUBLIC_SOURCES, canonical, fingerprint,
                       file_digest, identity, safe_file, validate_package, student_projection,
                       student_audio, source_download_path, validate_response, grade_sections)
from .repository import Repository


def iso(epoch):
    return datetime.fromtimestamp(epoch,timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def epoch(value):
    return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()


def uid(value):
    try:
        if not isinstance(value,str): raise ValueError()
        return str(uuid.UUID(value))
    except (ValueError,TypeError,AttributeError):
        raise ExamError('INVALID_EXAM_UUID') from None


def owner_id(value):
    if not isinstance(value,str) or not value.strip() or len(value)>256:
        raise ExamError('UNAUTHORIZED',401)
    return value


def fields(payload,allowed,required=()):
    if not isinstance(payload,dict) or set(payload)-set(allowed) or not set(required).issubset(payload):
        raise ExamError('INVALID_EXAM_REQUEST')


class Service:
    def __init__(self,storage_root,now=time.time):
        self.root=Path(storage_root).resolve()
        self.root.mkdir(parents=True,exist_ok=True)
        self.repository=Repository(self.root/'exams.sqlite3')
        self.now=now

    def _revision(self,connection,exam_id,revision=None):
        identity(exam_id)
        if revision is None:
            row=connection.execute('SELECT revision FROM catalog WHERE exam_id=?',(exam_id,)).fetchone()
            if not row: raise ExamError('EXAM_NOT_FOUND',404)
            revision=row['revision']
        if not isinstance(revision,str) or not re.fullmatch('[a-f0-9]{64}',revision):
            raise ExamError('INVALID_EXAM_REVISION')
        row=connection.execute('SELECT * FROM revisions WHERE exam_id=? AND revision=?',(exam_id,revision)).fetchone()
        if not row: raise ExamError('EXAM_NOT_FOUND',404)
        return row,json.loads(row['exam_json']),json.loads(row['audio_json']) if row['audio_json'] else None

    def dry_run(self,owner,package_dir):
        owner=owner_id(owner)
        package=validate_package(package_dir)
        import_id=str(uuid.uuid4())
        staged=self.root/'imports'/import_id
        staged.parent.mkdir(parents=True,exist_ok=True)
        try:
            shutil.copytree(Path(package_dir).resolve(),staged)
            copied=validate_package(staged)
            if copied['manifest_digest']!=package['manifest_digest']:
                raise ExamError('EXAM_PACKAGE_CHANGED_DURING_IMPORT',409)
            # Persist complete bytes before publishing any database pointer.
            for path in staged.rglob('*'):
                if path.is_file():
                    with path.open('rb') as stream: os.fsync(stream.fileno())
            with self.repository.transaction(write=True) as connection:
                connection.execute('INSERT INTO imports(import_id,owner,manifest_digest,exam_id,revision,package_path,summary_json,created_at) VALUES(?,?,?,?,?,?,?,?)',
                    (import_id,owner,package['manifest_digest'],package['exam']['id'],package['exam']['revision'],str(staged),canonical(package['summary']),self.now()))
                exists=connection.execute('SELECT 1 FROM revisions WHERE exam_id=? AND revision=?',
                    (package['exam']['id'],package['exam']['revision'])).fetchone()
            return {'import_id':import_id,'exam_id':package['exam']['id'],'revision':package['exam']['revision'],
                    'manifest_digest':package['manifest_digest'],'content_digest':package['content_digest'],
                    'summary':package['summary'],'action':'unchanged' if exists else 'publish_revision',
                    'errors':[],'warnings':['AI results require assessment; machine audio ranges retain their review state.']}
        except BaseException:
            shutil.rmtree(staged,ignore_errors=True)
            raise

    def commit(self,owner,import_id,transaction_id,expected_manifest_digest):
        owner=owner_id(owner); import_id=uid(import_id); transaction_id=uid(transaction_id)
        with self.repository.transaction(write=True) as connection:
            prior=connection.execute('SELECT * FROM import_transactions WHERE owner=? AND transaction_id=?',(owner,transaction_id)).fetchone()
            if prior:
                if prior['import_id']!=import_id or prior['manifest_digest']!=expected_manifest_digest:
                    raise ExamError('IMPORT_TRANSACTION_CONFLICT',409)
                return json.loads(prior['result_json'])
            prepared=connection.execute('SELECT * FROM imports WHERE import_id=? AND owner=?',(import_id,owner)).fetchone()
            if not prepared: raise ExamError('EXAM_IMPORT_NOT_FOUND',404)
            if prepared['manifest_digest']!=expected_manifest_digest:
                raise ExamError('EXAM_IMPORT_DIGEST_CONFLICT',409)
            if prepared['state']=='committed':
                result=json.loads(prepared['result_json'])
            else:
                package=validate_package(prepared['package_path'])
                if package['manifest_digest']!=expected_manifest_digest:
                    raise ExamError('EXAM_PACKAGE_CHANGED_AFTER_DRY_RUN',409)
                existing=connection.execute('SELECT * FROM revisions WHERE exam_id=? AND revision=?',(prepared['exam_id'],prepared['revision'])).fetchone()
                final=self.root/'packages'/prepared['exam_id']/prepared['revision']
                if existing:
                    if json.loads(existing['exam_json'])!=package['exam'] or (json.loads(existing['audio_json']) if existing['audio_json'] else None)!=package['audio']:
                        raise ExamError('IMMUTABLE_EXAM_REVISION_CONFLICT',409)
                else:
                    final.parent.mkdir(parents=True,exist_ok=True)
                    if final.exists():
                        recovered=validate_package(final)
                        if recovered['exam']!=package['exam'] or recovered['audio']!=package['audio']:
                            raise ExamError('EXAM_CONTENT_STORAGE_CONFLICT',409)
                    else:
                        Path(prepared['package_path']).rename(final)
                    connection.execute('INSERT INTO revisions VALUES(?,?,?,?,?,?,?,?)',
                        (prepared['exam_id'],prepared['revision'],package['content_digest'],expected_manifest_digest,
                         str(final),canonical(package['exam']),canonical(package['audio']) if package['audio'] is not None else None,self.now()))
                    connection.execute('INSERT INTO catalog VALUES(?,?) ON CONFLICT(exam_id) DO UPDATE SET revision=excluded.revision',(prepared['exam_id'],prepared['revision']))
                result={'import_id':import_id,'exam_id':prepared['exam_id'],'revision':prepared['revision'],
                        'manifest_digest':expected_manifest_digest,'state':'committed','content_unchanged':bool(existing)}
                connection.execute('UPDATE imports SET state=?,result_json=? WHERE import_id=?',('committed',canonical(result),import_id))
            connection.execute('INSERT INTO import_transactions VALUES(?,?,?,?,?)',(owner,transaction_id,import_id,expected_manifest_digest,canonical(result)))
        # An unchanged transport repack can be discarded only after commit.
        staged=Path(prepared['package_path'])
        if staged.is_relative_to(self.root/'imports'):
            shutil.rmtree(staged,ignore_errors=True)
        return result

    def catalog(self):
        with self.repository.transaction() as connection:
            rows=connection.execute('SELECT r.exam_json,r.audio_json FROM catalog c JOIN revisions r USING(exam_id,revision) ORDER BY c.exam_id').fetchall()
        exams=[]
        for row in rows:
            exam=json.loads(row['exam_json'])
            exams.append({k:copy.deepcopy(exam[k]) for k in ('id','revision','title','language','level','audience','session','interactive_section_ids')}|
                {'sections':[{k:s[k] for k in ('id','title','status','max_score_units','time_limit_seconds') if k in s} for s in exam['sections']],
                 'download_bytes':sum(s['bytes'] for s in exam['sources'] if s['id'] in PUBLIC_SOURCES)})
        return {'schema_version':'1.1','exams':exams}

    def student_package(self,exam_id,revision=None):
        with self.repository.transaction() as connection:
            _,exam,audio=self._revision(connection,exam_id,revision)
        return {'schema_version':'1.1','exam':student_projection(exam),'audio':student_audio(audio)}

    def resolve_asset(self,exam_id,revision,source_id):
        if source_id not in PUBLIC_SOURCES: raise ExamError('EXAM_SOURCE_NOT_FOUND',404)
        with self.repository.transaction() as connection:
            row,exam,_=self._revision(connection,exam_id,revision)
        source=next((s for s in exam['sources'] if s['id']==source_id),None)
        if not source: raise ExamError('EXAM_SOURCE_NOT_FOUND',404)
        path=safe_file(row['package_path'],source['path'])
        if not path.is_file() or path.stat().st_size!=source['bytes'] or file_digest(path)!=source['sha256']:
            raise ExamError('EXAM_ASSET_DAMAGED',503)
        return {'path':path,'bytes':source['bytes'],'sha256':source['sha256'],'media_type':source['media_type']}

    def download_metadata(self,exam_id,revision,source_id):
        result=self.resolve_asset(exam_id,revision,source_id)
        return {k:v for k,v in result.items() if k!='path'}|{'download_path':source_download_path(exam_id,revision,source_id)}

    def _attempt(self,connection,owner,attempt_id):
        row=connection.execute('SELECT * FROM attempts WHERE owner=? AND attempt_id=?',(owner,attempt_id)).fetchone()
        if not row: raise ExamError('EXAM_ATTEMPT_NOT_FOUND',404)
        return json.loads(row['data_json'])

    def _save(self,connection,owner,data):
        connection.execute('UPDATE attempts SET version=?,data_json=?,updated_at=? WHERE owner=? AND attempt_id=?',
            (data['version'],canonical(data),self.now(),owner,data['id']))

    def _snapshot(self,data):
        result=copy.deepcopy(data)
        result.pop('creation_fingerprint',None)
        return result|{'server_time':iso(self.now())}

    def _start_section(self,data,exam,section_id):
        if section_id in data['section_started_at']: return
        data['section_started_at'][section_id]=iso(self.now())
        section=next(s for s in exam['sections'] if s['id']==section_id)
        if data['mode']=='exam' and section_id in {'reading','grammar'} and section.get('time_limit_seconds'):
            data['section_deadlines'][section_id]=iso(self.now()+section['time_limit_seconds'])

    def _refresh_result(self,data,exam):
        submitted=data['submitted_section_ids']
        data['result']=grade_sections(exam,data['responses'],submitted,data['assessments']) if submitted else None
        if set(submitted)==set(data['section_ids']):
            data['state']='grading_pending' if any(s['status']=='pending' for s in data['result']['sections']) else 'graded'

    def _expire(self,connection,owner,data,exam):
        due=[section for section,deadline in data['section_deadlines'].items()
             if section not in data['submitted_section_ids'] and self.now()>=epoch(deadline)]
        if due:
            data['submitted_section_ids'] += due
            for section in due: data['section_submission_reasons'][section]='deadline'
            data['version']+=1; data['updated_at']=iso(self.now())
            self._refresh_result(data,exam); self._save(connection,owner,data)
        return bool(due)

    def create_attempt(self,owner,payload):
        owner=owner_id(owner)
        fields(payload,{'attempt_id','exam_id','revision','mode','device_id','section_ids'}, {'attempt_id','exam_id','revision','mode','device_id'})
        attempt_id=uid(payload['attempt_id']); device=identity(payload['device_id'])
        if not isinstance(payload['mode'],str) or payload['mode'] not in {'exam','training'}: raise ExamError('INVALID_EXAM_MODE')
        with self.repository.transaction(write=True) as connection:
            _,exam,_=self._revision(connection,payload['exam_id'],payload['revision'])
            selected=payload.get('section_ids',exam['interactive_section_ids'])
            if (not isinstance(selected,list) or not selected or any(not isinstance(s,str) for s in selected)
                    or len(selected)!=len(set(selected)) or not set(selected).issubset(exam['interactive_section_ids'])):
                raise ExamError('INVALID_EXAM_SECTION_SELECTION')
            initial=fingerprint({'exam_id':exam['id'],'revision':exam['revision'],'mode':payload['mode'],'section_ids':selected})
            prior=connection.execute('SELECT data_json FROM attempts WHERE owner=? AND attempt_id=?',(owner,attempt_id)).fetchone()
            if prior:
                data=json.loads(prior['data_json'])
                if data['creation_fingerprint']!=initial: raise ExamError('EXAM_ATTEMPT_ID_CONFLICT',409)
                self._expire(connection,owner,data,exam)
                return self._snapshot(data)
            first=selected[0]; section=next(s for s in exam['sections'] if s['id']==first)
            data={'id':attempt_id,'owner_id':owner,'exam_id':exam['id'],'revision':exam['revision'],
                  'mode':payload['mode'],'device_id':device,'active_device_id':device,'section_ids':selected,'version':1,'state':'in_progress',
                  'responses':{},'progress':{'section_id':first,'task_id':section['tasks'][0]['id'],
                    'audio_cursor_ms':0,'elapsed_ms':{}},'submitted_section_ids':[],
                  'section_submission_reasons':{},'section_started_at':{},'section_deadlines':{},
                  'assessments':{},'result':None,'created_at':iso(self.now()),'updated_at':iso(self.now()),
                  'started_at':iso(self.now()),'creation_fingerprint':initial}
            self._start_section(data,exam,first)
            connection.execute('INSERT INTO attempts VALUES(?,?,?,?,?,?,?,?)',
                (owner,attempt_id,exam['id'],exam['revision'],1,canonical(data),self.now(),self.now()))
        return self._snapshot(data)

    def get_attempt(self,owner,attempt_id):
        owner=owner_id(owner); attempt_id=uid(attempt_id)
        with self.repository.transaction(write=True) as connection:
            data=self._attempt(connection,owner,attempt_id)
            _,exam,_=self._revision(connection,data['exam_id'],data['revision'])
            self._expire(connection,owner,data,exam)
        return self._snapshot(data)

    def list_attempts(self,owner):
        owner=owner_id(owner)
        with self.repository.transaction() as connection:
            ids=[row['attempt_id'] for row in connection.execute('SELECT attempt_id FROM attempts WHERE owner=? ORDER BY updated_at DESC,attempt_id',(owner,))]
        return {'attempts':[self.get_attempt(owner,value) for value in ids]}

    def _mutate(self,owner,attempt_id,payload,submit):
        owner=owner_id(owner); attempt_id=uid(attempt_id)
        allowed={'base_version','change_id','device_id','section_id','takeover'} if submit else {'base_version','change_id','device_id','responses','progress','state','takeover'}
        fields(payload,allowed,{'base_version','change_id','device_id'})
        change_id=uid(payload['change_id']); device=identity(payload['device_id'])
        if type(payload['base_version']) is not int or payload['base_version']<1: raise ExamError('INVALID_ATTEMPT_VERSION')
        if 'takeover' in payload and type(payload['takeover']) is not bool: raise ExamError('INVALID_EXAM_TAKEOVER')
        try: request_digest=fingerprint({'operation':'submit' if submit else 'update','payload':payload})
        except (ValueError,TypeError,UnicodeError): raise ExamError('INVALID_EXAM_REQUEST') from None
        failure=None
        with self.repository.transaction(write=True) as connection:
            data=self._attempt(connection,owner,attempt_id)
            _,exam,audio=self._revision(connection,data['exam_id'],data['revision'])
            self._expire(connection,owner,data,exam)
            previous=connection.execute('SELECT request_digest FROM attempt_changes WHERE owner=? AND attempt_id=? AND change_id=?',(owner,attempt_id,change_id)).fetchone()
            try:
                if previous:
                    if previous['request_digest']!=request_digest: raise ExamError('EXAM_CHANGE_ID_CONFLICT',409)
                else:
                    if payload['base_version']!=data['version']:
                        raise ExamError('EXAM_ATTEMPT_CONFLICT',409,{'current_version':data['version'],'attempt':self._snapshot(data)})
                    if device!=data['active_device_id'] and not payload.get('takeover'):
                        raise ExamError('EXAM_DEVICE_CONFLICT',409,{'current_version':data['version'],'attempt':self._snapshot(data)})
                    if not submit and set(data['submitted_section_ids'])==set(data['section_ids']):
                        raise ExamError('EXAM_ATTEMPT_SUBMITTED',409)
                    changed=copy.deepcopy(data)
                    changed['active_device_id']=device
                    if submit:
                        selected=[payload['section_id']] if 'section_id' in payload else changed['section_ids']
                        if any(not isinstance(s,str) for s in selected) or not set(selected).issubset(changed['section_ids']): raise ExamError('INVALID_EXAM_SECTION_SELECTION')
                        for section in selected:
                            if section not in changed['submitted_section_ids']:
                                changed['submitted_section_ids'].append(section)
                                changed['section_submission_reasons'][section]='user'
                    else:
                        patch=payload.get('responses',{})
                        if not isinstance(patch,dict): raise ExamError('INVALID_EXAM_RESPONSES')
                        lookup={i['id']:(s['id'],i) for s in exam['sections'] if s['id'] in changed['section_ids'] for t in s['tasks'] for i in t['items']}
                        for item_id,answer in patch.items():
                            if item_id not in lookup: raise ExamError('UNKNOWN_EXAM_RESPONSE')
                            section,item=lookup[item_id]
                            if section in changed['submitted_section_ids']: raise ExamError('EXAM_SECTION_SUBMITTED',409)
                            changed['responses'][item_id]=validate_response(item,answer)
                        progress=payload.get('progress',{})
                        fields(progress,{'section_id','task_id','audio_cursor_ms','elapsed_ms'})
                        section_id=progress.get('section_id',changed['progress']['section_id'])
                        if section_id not in changed['section_ids']: raise ExamError('INVALID_EXAM_SECTION_SELECTION')
                        if section_id in changed['submitted_section_ids'] and progress: raise ExamError('EXAM_SECTION_SUBMITTED',409)
                        section=next(s for s in exam['sections'] if s['id']==section_id)
                        task_id=progress.get('task_id',changed['progress']['task_id'] if section_id==changed['progress']['section_id'] else section['tasks'][0]['id'])
                        if task_id not in {t['id'] for t in section['tasks']}: raise ExamError('INVALID_EXAM_PROGRESS_TASK')
                        cursor=progress.get('audio_cursor_ms',changed['progress']['audio_cursor_ms'])
                        if type(cursor) is not int or not 0<=cursor<=((audio or {}).get('source',{}).get('duration_ms',0)):
                            raise ExamError('INVALID_EXAM_AUDIO_CURSOR')
                        elapsed=progress.get('elapsed_ms',changed['progress']['elapsed_ms'])
                        if (not isinstance(elapsed,dict) or not set(elapsed).issubset(changed['section_ids'])
                                or any(type(v) is not int or not 0<=v<=604800000 for v in elapsed.values())):
                            raise ExamError('INVALID_EXAM_ELAPSED_TIME')
                        self._start_section(changed,exam,section_id)
                        changed['progress']={'section_id':section_id,'task_id':task_id,'audio_cursor_ms':cursor,
                            'elapsed_ms':changed['progress']['elapsed_ms']|elapsed}
                        state=payload.get('state',changed['state'])
                        if not isinstance(state,str) or state not in {'in_progress','interrupted'}: raise ExamError('INVALID_EXAM_ATTEMPT_STATE')
                        changed['state']=state
                    changed['device_id']=device; changed['version']+=1; changed['updated_at']=iso(self.now())
                    self._refresh_result(changed,exam)
                    self._save(connection,owner,changed)
                    connection.execute('INSERT INTO attempt_changes VALUES(?,?,?,?)',(owner,attempt_id,change_id,request_digest))
                    data=changed
            except ExamError as error:
                failure=error
        # Deadline transitions persist even if a late update is rejected.
        if failure: raise failure
        return self._snapshot(data)

    def update_attempt(self,owner,attempt_id,payload):
        return self._mutate(owner,attempt_id,payload,False)

    def submit_attempt(self,owner,attempt_id,payload):
        return self._mutate(owner,attempt_id,payload,True)

    def _assessment_context(self,data,exam,task_id):
        matches=[(s,t) for s in exam['sections'] for t in s['tasks'] if t['id']==task_id]
        if len(matches)!=1: raise ExamError('EXAM_TASK_NOT_FOUND',404)
        section,task=matches[0]
        if section['id'] not in data['section_ids'] or section['id'] not in data['submitted_section_ids']:
            raise ExamError('EXAM_ASSESSMENT_NOT_READY',409)
        if task_id not in {'grammar-V','grammar-VI'}: raise ExamError('EXAM_TASK_NOT_ASSESSABLE')
        return {'exam':copy.deepcopy(exam),'task':copy.deepcopy(task),'responses':copy.deepcopy(data['responses']),'attempt':self._snapshot(data)}

    def assessment_context(self,owner,attempt_id,task_id):
        data=self.get_attempt(owner,attempt_id)
        with self.repository.transaction() as connection:
            _,exam,_=self._revision(connection,data['exam_id'],data['revision'])
        return self._assessment_context(data,exam,task_id)

    def assessment_input(self,owner,attempt_id,task_id,feedback_language='pl'):
        context=self.assessment_context(owner,attempt_id,task_id)
        return {'request':build_grading_request(context['exam'],task_id,context['responses'],feedback_language),
                'contract':compile_assessment(context['task'],context['exam']['id'])}

    def record_assessment(self,owner,attempt_id,task_id,result,provenance,*,server_verified=False):
        owner=owner_id(owner); attempt_id=uid(attempt_id)
        fields(provenance,{'provider','mode','model','reasoning_effort','revision','contract_sha256','request_id','request_sha256','prompt_version'},
               {'provider','mode','model','reasoning_effort','revision','contract_sha256'})
        if provenance['provider']!='openai' or provenance['mode'] not in {'personalKey','subscription','operator'}:
            raise ExamError('INVALID_EXAM_ASSESSMENT_PROVENANCE')
        if not server_verified and provenance['mode']!='personalKey': raise ExamError('UNVERIFIED_SERVER_ASSESSMENT',403)
        inference_settings(provenance)
        if any(not isinstance(value,str) or len(value)>500 for value in provenance.values()):
            raise ExamError('INVALID_EXAM_ASSESSMENT_PROVENANCE')
        with self.repository.transaction(write=True) as connection:
            data=self._attempt(connection,owner,attempt_id)
            _,exam,_=self._revision(connection,data['exam_id'],data['revision'])
            context=self._assessment_context(data,exam,task_id)
            contract=compile_assessment(context['task'],exam['id'])
            if provenance['revision']!=data['revision'] or provenance['contract_sha256']!=contract['contract_sha256']:
                raise ExamError('EXAM_ASSESSMENT_REVISION_CONFLICT',409)
            try: value=validate_assessment_result(contract,result)
            except ValueError: raise ExamError('INVALID_EXAM_ASSESSMENT_RESULT') from None
            record={'task_id':task_id,**value,'origin':'server_provider' if server_verified else 'client_personal_key',
                    'provenance':copy.deepcopy(provenance),'source_refs':contract['source_refs']}
            prior=data['assessments'].get(task_id)
            if prior:
                if prior!=record: raise ExamError('EXAM_ASSESSMENT_ALREADY_RECORDED',409)
                return self._snapshot(data)
            data['assessments'][task_id]=record; data['version']+=1; data['updated_at']=iso(self.now())
            self._refresh_result(data,exam); self._save(connection,owner,data)
        return self._snapshot(data)

    def handle(self,route,owner,payload=None,params=None,query=None):
        from .api import handle
        return handle(self,route,owner,payload,params,query)
