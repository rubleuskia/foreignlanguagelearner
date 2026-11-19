import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import uuid

from backend.exams.assessment_contract import compile_assessment
from backend.exams.contract import ExamError, file_digest, fingerprint, validate_package
from backend.exams.service import Service
from backend.exams.testing import synthetic_profile

ROOT=Path(__file__).resolve().parents[2]


def write_json(path,value):
    Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')


def refresh_package(folder,change_title=None):
    exam=json.loads((folder/'exam.json').read_text())
    audio=json.loads((folder/'audio.json').read_text())
    if change_title: exam['title']=change_title
    exam.pop('revision',None)
    exam['revision']=fingerprint({'exam':exam,'audio':audio})
    write_json(folder/'exam.json',exam)
    refs=[{'source_id':s['id'],'url':s['url'],'sha256':s['sha256']} for s in exam['sources']]
    rows=[{'path':p.relative_to(folder).as_posix(),'bytes':p.stat().st_size,'sha256':file_digest(p),'source_refs':refs}
          for p in sorted(folder.rglob('*')) if p.is_file() and p!=folder/'artifact-manifest.json']
    write_json(folder/'artifact-manifest.json',{'exam_id':exam['id'],'revision':exam['revision'],'source_refs':refs,'artifacts':rows})
    return exam


def fixture(folder):
    folder.mkdir()
    exam=synthetic_profile()
    exam.pop('source_selection',None)
    exam['schema_version']='1.1'
    exam['interactive_section_ids']=['listening','reading','grammar']
    exam['provenance']={'profile_sha256':'a'*64,'archive_url':'https://example.test/archive','generator':'backend-test'}
    (folder/'sources').mkdir()
    sources=[]
    for role,kind in [('paper','application/pdf'),('keys','application/pdf'),('audio','audio/mpeg')]:
        path=folder/'sources'/f'{role}.bin'
        path.write_bytes(f'Isolated test source {role}'.encode())
        source={'id':role,'url':f'https://example.test/{role}','path':path.relative_to(folder).as_posix(),
                'sha256':file_digest(path),'bytes':path.stat().st_size,'media_type':kind}
        if role!='audio': source['page_count']=64
        sources.append(source)
    exam['sources']=sources
    for section in exam['sections']:
        for task in section['tasks']:
            if task['id'] in {'grammar-V','grammar-VI'}:
                task['ai_assessment']=compile_assessment(task,exam['id'])
    source=next(s for s in sources if s['id']=='audio')
    audio={'schema_version':1,'source':{'source_id':'audio','sha256':source['sha256'],'duration_ms':30000},
           'timestamp_unit':'milliseconds_relative_to_original_audio','review_status':'requires_listening_review',
           'tasks':[{'task_label':task['label'],'occurrences':[{'id':f'occurrence-{index}',
               'source_id':'audio','start_ms':index*3000,'end_ms':index*3000+2000,'role':'primary',
               'review_status':'requires_listening_review','evidence':{'private_transcript':'not public'}}]}
               for index,task in enumerate(next(s for s in exam['sections'] if s['id']=='listening')['tasks'])]}
    write_json(folder/'exam.json',exam)
    write_json(folder/'audio.json',audio)
    (folder/'transport-note.txt').write_text('Not examination content.\n')
    return refresh_package(folder)


class ExamServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.package=self.root/'package'
        self.exam=fixture(self.package)
        self.clock=[1800000000]
        self.service=Service(self.root/'durable',now=lambda:self.clock[0])

    def tearDown(self): self.temp.cleanup()

    def publish(self,folder=None):
        prepared=self.service.dry_run('operator',folder or self.package)
        result=self.service.commit('operator',prepared['import_id'],str(uuid.uuid4()),prepared['manifest_digest'])
        return prepared,result

    def attempt(self,sections=('reading',),mode='exam',owner='alice'):
        return self.service.create_attempt(owner,{'attempt_id':str(uuid.uuid4()),'exam_id':self.exam['id'],
            'revision':self.exam['revision'],'mode':mode,'device_id':'device-a','section_ids':list(sections)})

    def patch(self,snapshot,**kwargs):
        return {'base_version':snapshot['version'],'change_id':str(uuid.uuid4()),'device_id':'device-a',**kwargs}

    def assert_code(self,code,call):
        with self.assertRaises(ExamError) as raised: call()
        self.assertEqual(raised.exception.code,code)
        return raised.exception

    def test_dry_run_is_persistent_but_not_published_and_commit_is_idempotent(self):
        prepared=self.service.dry_run('operator',self.package)
        self.assertEqual(self.service.catalog()['exams'],[])
        restarted=Service(self.root/'durable',now=lambda:self.clock[0])
        tx=str(uuid.uuid4())
        committed=restarted.commit('operator',prepared['import_id'],tx,prepared['manifest_digest'])
        self.assertEqual(committed,restarted.commit('operator',prepared['import_id'],tx,prepared['manifest_digest']))
        self.assertEqual(len(restarted.catalog()['exams']),1)
        self.assert_code('IMPORT_TRANSACTION_CONFLICT',lambda:restarted.commit('operator',prepared['import_id'],tx,'d'*64))

    def test_source_or_artifact_tamper_rejected_before_publication(self):
        (self.package/'sources/paper.bin').write_bytes(b'changed')
        self.assert_code('EXAM_ARTIFACT_MISMATCH',lambda:self.service.dry_run('operator',self.package))
        self.assertEqual(self.service.catalog()['exams'],[])

    def test_staged_tamper_after_dry_run_does_not_publish(self):
        prepared=self.service.dry_run('operator',self.package)
        staged=self.root/'durable/imports'/prepared['import_id']/'exam.json'
        staged.write_text(staged.read_text()+' ')
        self.assert_code('EXAM_ARTIFACT_MISMATCH',lambda:self.service.commit('operator',prepared['import_id'],str(uuid.uuid4()),prepared['manifest_digest']))
        self.assertEqual(self.service.catalog()['exams'],[])

    def test_content_revision_rejects_changed_question_even_with_rehashed_transport(self):
        exam=json.loads((self.package/'exam.json').read_text())
        exam['title']='Changed without new content revision'
        write_json(self.package/'exam.json',exam)
        manifest=json.loads((self.package/'artifact-manifest.json').read_text())
        row=next(r for r in manifest['artifacts'] if r['path']=='exam.json')
        row.update(bytes=(self.package/'exam.json').stat().st_size,sha256=file_digest(self.package/'exam.json'))
        write_json(self.package/'artifact-manifest.json',manifest)
        self.assert_code('EXAM_REVISION_MISMATCH',lambda:self.service.dry_run('operator',self.package))

    def test_repack_is_noop_and_old_revision_does_not_downgrade_catalog(self):
        self.publish()
        newer=self.root/'newer'; shutil.copytree(self.package,newer)
        new_exam=refresh_package(newer,'A newer reviewed title')
        self.publish(newer)
        repack=self.root/'repack'; shutil.copytree(self.package,repack)
        (repack/'transport-note.txt').write_text('Updated transport documentation only.\n')
        refresh_package(repack)
        _,result=self.publish(repack)
        self.assertTrue(result['content_unchanged'])
        self.assertEqual(self.service.catalog()['exams'][0]['revision'],new_exam['revision'])
        self.assertEqual(self.service.student_package(self.exam['id'],self.exam['revision'])['exam']['revision'],self.exam['revision'])

    def test_symlink_traversal_and_unlisted_files_are_rejected(self):
        (self.package/'extra.txt').write_text('unlisted')
        self.assert_code('UNLISTED_EXAM_ARTIFACT',lambda:validate_package(self.package))
        (self.package/'extra.txt').unlink()
        (self.package/'link').symlink_to(self.root)
        self.assert_code('EXAM_SYMLINK_NOT_ALLOWED',lambda:validate_package(self.package))
        (self.package/'link').unlink()
        manifest=json.loads((self.package/'artifact-manifest.json').read_text())
        manifest['artifacts'][0]['path']='../escape'
        write_json(self.package/'artifact-manifest.json',manifest)
        self.assert_code('INVALID_EXAM_PATH',lambda:validate_package(self.package))

    def test_student_projection_excludes_keys_rubrics_and_audio_evidence(self):
        self.publish()
        package=self.service.student_package(self.exam['id'],self.exam['revision'])
        text=json.dumps(package)
        for forbidden in ('accepted_answers','reference_answer','ai_assessment','rubric','private_transcript','"keys"'):
            self.assertNotIn(forbidden,text)
        self.assertEqual(len(package['exam']['sections']),5)
        self.assertEqual({s['id'] for s in package['exam']['sources']},{'paper','audio'})
        self.assert_code('EXAM_SOURCE_NOT_FOUND',lambda:self.service.resolve_asset(self.exam['id'],self.exam['revision'],'keys'))
        self.assertEqual(self.service.download_metadata(self.exam['id'],self.exam['revision'],'audio')['download_path'].split('/')[-1],'content')

    def test_resolve_asset_detects_storage_corruption(self):
        self.publish()
        asset=self.service.resolve_asset(self.exam['id'],self.exam['revision'],'audio')
        asset['path'].write_bytes(b'corrupt')
        self.assert_code('EXAM_ASSET_DAMAGED',lambda:self.service.resolve_asset(self.exam['id'],self.exam['revision'],'audio'))

    def test_attempt_survives_service_restart_and_is_owner_scoped(self):
        self.publish(); attempt=self.attempt()
        saved=self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={'reading-I-1':'reading-I-option-1-b'}))
        restarted=Service(self.root/'durable',now=lambda:self.clock[0])
        self.assertEqual(restarted.get_attempt('alice',attempt['id'])['responses'],saved['responses'])
        self.assert_code('EXAM_ATTEMPT_NOT_FOUND',lambda:restarted.get_attempt('bob',attempt['id']))
        self.assertEqual(restarted.list_attempts('bob')['attempts'],[])

    def test_optimistic_conflict_and_change_replay_preserve_answers(self):
        self.publish(); attempt=self.attempt()
        request=self.patch(attempt,responses={'reading-I-1':'reading-I-option-1-b'})
        saved=self.service.update_attempt('alice',attempt['id'],request)
        self.assertEqual(self.service.update_attempt('alice',attempt['id'],request)['version'],saved['version'])
        self.assert_code('EXAM_ATTEMPT_CONFLICT',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={'reading-I-1':'reading-I-option-1-a'})))
        changed=copy.deepcopy(request); changed['responses']['reading-I-1']='reading-I-option-1-a'
        self.assert_code('EXAM_CHANGE_ID_CONFLICT',lambda:self.service.update_attempt('alice',attempt['id'],changed))
        self.assertEqual(self.service.get_attempt('alice',attempt['id'])['responses'],saved['responses'])

    def test_device_takeover_requires_explicit_owner_confirmation(self):
        self.publish(); attempt=self.attempt(sections=('listening',))
        request=self.patch(attempt,device_id='device-b',progress={'audio_cursor_ms':1234})
        self.assert_code('EXAM_DEVICE_CONFLICT',lambda:self.service.update_attempt('alice',attempt['id'],request))
        request['takeover']=True
        saved=self.service.update_attempt('alice',attempt['id'],request)
        self.assertEqual(saved['active_device_id'],'device-b')
        self.assertEqual(saved['progress']['audio_cursor_ms'],1234)
        self.assert_code('EXAM_DEVICE_CONFLICT',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(saved)))

    def test_deadline_persists_and_late_offline_update_does_not_reopen_section(self):
        self.publish(); attempt=self.attempt()
        self.clock[0]+=2400
        self.assert_code('EXAM_ATTEMPT_CONFLICT',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={'reading-I-1':'reading-I-option-1-b'},progress={'elapsed_ms':{'reading':0}})))
        saved=self.service.get_attempt('alice',attempt['id'])
        self.assertEqual(saved['submitted_section_ids'],['reading'])
        self.assertEqual(saved['state'],'graded')
        self.assertEqual(saved['section_submission_reasons']['reading'],'deadline')
        self.assertEqual(saved['responses'],{})

    def test_training_has_no_deadline_and_partial_submit_keeps_other_sections_open(self):
        self.publish(); training=self.attempt(mode='training')
        self.clock[0]+=86400
        self.assertEqual(self.service.get_attempt('alice',training['id'])['submitted_section_ids'],[])
        attempt=self.attempt(sections=('reading','grammar'))
        submitted=self.service.submit_attempt('alice',attempt['id'],self.patch(attempt,section_id='reading'))
        self.assertEqual(submitted['state'],'in_progress')
        self.assert_code('EXAM_SECTION_SUBMITTED',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(submitted,responses={'reading-I-1':'reading-I-option-1-b'})))
        updated=self.service.update_attempt('alice',attempt['id'],self.patch(submitted,progress={'section_id':'grammar'}))
        self.assertIn('grammar',updated['section_deadlines'])

    def test_unique_token_partial_credit_is_scored_on_server(self):
        self.publish(); attempt=self.attempt(sections=('listening',))
        task=next(t for s in self.exam['sections'] for t in s['tasks'] if t['id']=='listening-V')
        item=next(i for i in task['items'] if len(i['grading']['accepted_answers'])==2)
        correct=item['grading']['accepted_answers'][0]
        saved=self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={item['id']:f'{correct};{correct};99'}))
        result=self.service.submit_attempt('alice',attempt['id'],self.patch(saved))['result']
        row=next(r for s in result['sections'] for r in s['items'] if r['item_id']==item['id'])
        self.assertEqual(row['awarded_score_units'],item['max_score_units']//2)
        self.assertEqual(row['status'],'partial')
        self.assertEqual(row['task_id'],'listening-V')

    def test_assessment_is_only_after_submission_and_personal_origin_is_not_server(self):
        self.publish(); attempt=self.attempt(sections=('grammar',))
        self.assert_code('EXAM_ASSESSMENT_NOT_READY',lambda:self.service.assessment_context('alice',attempt['id'],'grammar-V'))
        submitted=self.service.submit_attempt('alice',attempt['id'],self.patch(attempt))
        context=self.service.assessment_context('alice',attempt['id'],'grammar-V')
        contract=compile_assessment(context['task'],self.exam['id'])
        provenance={'provider':'openai','mode':'personalKey','model':'gpt-5-mini','reasoning_effort':'minimal',
                    'revision':self.exam['revision'],'contract_sha256':contract['contract_sha256']}
        saved=self.service.record_assessment('alice',attempt['id'],'grammar-V',{'score_units':25,'rationale':'Partial according to official source.'},provenance)
        self.assertEqual(saved['assessments']['grammar-V']['origin'],'client_personal_key')
        self.assertEqual(saved['state'],'grading_pending')
        self.assertEqual(self.service.record_assessment('alice',attempt['id'],'grammar-V',{'score_units':25,'rationale':'Partial according to official source.'},provenance)['version'],saved['version'])
        self.assert_code('INVALID_EXAM_ASSESSMENT_RESULT',lambda:self.service.record_assessment('alice',attempt['id'],'grammar-VI',{'score_units':999,'rationale':'no'},provenance|{'contract_sha256':compile_assessment(self.service.assessment_context('alice',attempt['id'],'grammar-VI')['task'],self.exam['id'])['contract_sha256']}))

    def test_source_bound_listening_assessment_uses_generic_mode_after_submission(self):
        exam=copy.deepcopy(self.exam)
        task=copy.deepcopy(next(t for s in exam['sections'] for t in s['tasks'] if t['id']=='grammar-VI'))
        task.update(id='listening-V',label='V',position=5)
        for index,item in enumerate(task['items'],1):item['id']=f'listening-V-open-{index}'
        task['ai_assessment']=compile_assessment(task,exam['id'])
        listening=next(s for s in exam['sections'] if s['id']=='listening')
        listening['tasks']=[task if t['id']=='listening-V' else t for t in listening['tasks']]
        listening['max_score_units']=sum(t['max_score_units'] for t in listening['tasks'])
        write_json(self.package/'exam.json',exam)
        self.exam=refresh_package(self.package)
        self.publish();attempt=self.attempt(sections=('listening',))
        self.assert_code('EXAM_ASSESSMENT_NOT_READY',lambda:self.service.assessment_context('alice',attempt['id'],'listening-V'))
        self.service.submit_attempt('alice',attempt['id'],self.patch(attempt))
        context=self.service.assessment_context('alice',attempt['id'],'listening-V')
        self.assertEqual(context['task']['id'],'listening-V')
        compiled=self.service.assessment_input('alice',attempt['id'],'listening-V')
        self.assertEqual(compiled['contract']['max_score_units'],500)
        self.assertEqual(len(compiled['request']['payload']['responses']),5)
        self.assertTrue(all(r['item_id'].startswith('listening-V-open-')
                            for r in compiled['request']['payload']['responses']))

    def test_bad_answers_cannot_submit_unknown_items_or_overfill_numeric_slots(self):
        self.publish(); attempt=self.attempt(sections=('listening',))
        self.assert_code('UNKNOWN_EXAM_RESPONSE',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={'not-in-revision':'x'})))
        task=next(t for s in self.exam['sections'] for t in s['tasks'] if t['id']=='listening-V')
        item=next(i for i in task['items'] if len(i['grading']['accepted_answers'])==2)
        self.assert_code('TOO_MANY_EXAM_TOKENS',lambda:self.service.update_attempt('alice',attempt['id'],self.patch(attempt,responses={item['id']:'1,2,3'})))


    def test_operator_assessment_requires_server_verification(self):
        self.publish(); attempt=self.attempt(sections=('grammar',),mode='training')
        attempt=self.service.submit_attempt('alice',attempt['id'],self.patch(attempt,section_id='grammar'))
        contract=self.service.assessment_input('alice',attempt['id'],'grammar-V')['contract']
        provenance={'provider':'openai','mode':'operator','model':'gpt-5-mini','reasoning_effort':'minimal',
                    'revision':self.exam['revision'],'contract_sha256':contract['contract_sha256']}
        result={'score_units':25,'rationale':'One official component is correct.'}
        self.assert_code('UNVERIFIED_SERVER_ASSESSMENT',lambda:self.service.record_assessment(
            'alice',attempt['id'],'grammar-V',result,provenance))
        recorded=self.service.record_assessment('alice',attempt['id'],'grammar-V',result,provenance,server_verified=True)
        self.assertEqual(recorded['assessments']['grammar-V']['origin'],'server_provider')
        self.assertEqual(recorded['assessments']['grammar-V']['provenance']['mode'],'operator')

    def test_subscription_result_recovery_records_once_with_server_provenance(self):
        from unittest.mock import patch
        from backend.exams.assessment import prepare
        from backend.translation.service import TranslationService
        self.publish(); attempt=self.attempt(sections=('grammar',),mode='training')
        attempt=self.service.submit_attempt('alice',attempt['id'],self.patch(attempt,section_id='grammar'))
        payload=prepare(self.service,'alice',{'attempt_id':attempt['id'],'task_id':'grammar-V',
            'model':'gpt-5-mini','reasoning_effort':'minimal'})
        result={'score_units':25,'rationale':'One official component is correct.'}
        with patch('backend.exams.runtime.service',return_value=self.service):
            TranslationService._save_assessment('alice',payload,result)
            first=self.service.get_attempt('alice',attempt['id'])
            TranslationService._save_assessment('alice',payload,result)
        saved=self.service.get_attempt('alice',attempt['id'])
        self.assertEqual(first['version'],saved['version'])
        self.assertEqual(saved['assessments']['grammar-V']['origin'],'server_provider')
        self.assertEqual(saved['assessments']['grammar-V']['provenance']['mode'],'subscription')


if __name__=='__main__': unittest.main()
