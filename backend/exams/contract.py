"""Validated immutable exam packages and answer-key-free student projections."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import re
import unicodedata
from urllib.parse import quote, urlsplit

from backend.cloud.errors import CloudError
from .assessment_contract import is_assessment_task, compile_assessment
from .token_membership import normalize_token, tokens, validate_membership

HERE = Path(__file__).resolve().parent
ACTIVE_SECTIONS = {'listening', 'reading', 'grammar'}
PUBLIC_SOURCES = {'paper', 'audio'}


class ExamError(CloudError):
    def __init__(self, code, status=400, details=None):
        super().__init__(code, status)
        self.details = details or {}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024*1024), b''):
            digest.update(data)
    return digest.hexdigest()


def load_json(path):
    if Path(path).stat().st_size > 16*1024*1024:
        raise ExamError('EXAM_METADATA_TOO_LARGE', 413)
    return json.loads(Path(path).read_text(encoding='utf-8'))


def safe_file(root, relative):
    if not isinstance(relative, str) or not relative or '\\' in relative:
        raise ExamError('INVALID_EXAM_PATH')
    raw = Path(relative)
    if raw.is_absolute() or any(part in {'.', '..'} for part in raw.parts):
        raise ExamError('INVALID_EXAM_PATH')
    root = Path(root).resolve()
    path = root/raw
    if not path.resolve().is_relative_to(root) or path.resolve() == root:
        raise ExamError('INVALID_EXAM_PATH')
    if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root and parent.is_relative_to(root)):
        raise ExamError('EXAM_SYMLINK_NOT_ALLOWED')
    return path


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def identity(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,159}', value):
        raise ExamError('INVALID_EXAM_ID')
    return value


def validate_exam(exam, audio=None):
    from jsonschema import Draft202012Validator, FormatChecker
    errors = sorted(Draft202012Validator(load_json(HERE/'exam.schema.json'),
                    format_checker=FormatChecker()).iter_errors(exam), key=lambda e:str(list(e.path)))
    if errors:
        raise ExamError('INVALID_EXAM_SCHEMA', details={'issues': [f'{list(e.path)}: {e.message}' for e in errors[:8]]})
    identity(exam['id'])
    sources = {s['id']:s for s in exam['sources']}
    if len(sources) != len(exam['sources']) or set(sources) != {'paper', 'keys', 'audio'}:
        raise ExamError('INVALID_EXAM_SOURCES')
    for source in sources.values():
        parsed = urlsplit(source['url'])
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
            raise ExamError('INVALID_EXAM_SOURCE_URL')
    for node in nodes(exam):
        for ref in node.get('source_refs', []):
            source = sources.get(ref.get('source_id'))
            if not source or (source['media_type']=='application/pdf' and
                              (type(ref.get('page')) is not int or not 1 <= ref['page'] <= source.get('page_count',0))):
                raise ExamError('INVALID_EXAM_SOURCE_REFERENCE')
    ids = [node['id'] for node in nodes(exam['sections']) if 'id' in node]
    if len(ids) != len(set(ids)):
        raise ExamError('DUPLICATE_EXAM_CONTENT_ID')
    section_ids = {s['id'] for s in exam['sections'] if s.get('status') != 'source_missing'}
    if not set(exam['interactive_section_ids']).issubset(section_ids & ACTIVE_SECTIONS):
        raise ExamError('INVALID_INTERACTIVE_SECTIONS')
    if len({s['position'] for s in exam['sections']}) != len(exam['sections']):
        raise ExamError('DUPLICATE_EXAM_POSITION')
    for section in exam['sections']:
        tasks = section['tasks']
        if section.get('status') == 'source_missing':
            if tasks:
                raise ExamError('INVENTED_MISSING_SECTION')
            continue
        if not tasks or len({t['position'] for t in tasks}) != len(tasks):
            raise ExamError('INVALID_EXAM_TASK_ORDER')
        selection = section.get('selection')
        if selection:
            if set(selection['task_ids']) != {t['id'] for t in tasks} or any(t['max_score_units'] != section['max_score_units'] for t in tasks):
                raise ExamError('INVALID_EXAM_SELECTION')
        elif sum(t['max_score_units'] for t in tasks) != section['max_score_units']:
            raise ExamError('INVALID_EXAM_SCORE_TOTAL')
        for task in tasks:
            items = task['items']
            if not items or len({i['position'] for i in items}) != len(items):
                raise ExamError('INVALID_EXAM_ITEM_ORDER')
            if all(i['max_score_units'] is not None for i in items):
                if sum(i['max_score_units'] for i in items) != task['max_score_units']:
                    raise ExamError('INVALID_EXAM_SCORE_TOTAL')
            elif any(i['grading']['mode'] not in {'ai_stub','manual'} for i in items):
                raise ExamError('INVALID_SHARED_EXAM_SCORE')
            item_ids = {i['id'] for i in items}
            options = {o['id'] for o in task['options']}
            for block in task['blocks']:
                if block.get('is_scored') is True and block['type'] == 'example':
                    raise ExamError('SCORED_EXAM_EXAMPLE')
                if not set(re.findall(r'\{\{([^{}]+)\}\}', block['text'])).issubset(item_ids):
                    raise ExamError('UNKNOWN_EXAM_GAP')
            if is_assessment_task(task):
                if task.get('ai_assessment') != compile_assessment(task, exam['id']):
                    raise ExamError('INVALID_EXAM_AI_CONTRACT')
            display_codes = task.get('presentation',{}).get('display_codes',{})
            if display_codes and (not set(display_codes).issubset(options) or len(set(display_codes.values())) != len(display_codes)):
                raise ExamError('INVALID_EXAM_DISPLAY_CODES')
            for item in items:
                grading = item['grading']
                mode = grading['mode']
                allowed = set(item.get('option_ids',[]))
                accepted = grading['accepted_answers']
                if not allowed.issubset(options) or (item['response_type'] in {'single_choice','multi_choice'} and not allowed):
                    raise ExamError('INVALID_EXAM_OPTION_REFERENCE')
                if mode in {'exact','set','token_membership'} and (not accepted or item['max_score_units'] is None):
                    raise ExamError('MISSING_EXAM_KEY')
                for answer in accepted:
                    if mode == 'set' and (not isinstance(answer,list) or not set(answer).issubset(allowed)):
                        raise ExamError('INVALID_EXAM_KEY')
                    if mode == 'exact' and (not isinstance(answer,str) or (allowed and answer not in allowed)):
                        raise ExamError('INVALID_EXAM_KEY')
                if mode == 'token_membership':
                    try:
                        validate_membership(item)
                    except ValueError:
                        raise ExamError('INVALID_EXAM_MEMBERSHIP_RULE') from None
                originals = grading.get('source_accepted_option_ids',[])
                if display_codes and originals and (not set(originals).issubset(display_codes) or
                        set(accepted)!={display_codes[x] for x in originals}):
                    raise ExamError('EXAM_KEY_MAPPING_CHANGED')
    if 'listening' in exam['interactive_section_ids']:
        validate_audio(audio, exam)
    expected = fingerprint({'exam':{k:v for k,v in exam.items() if k!='revision'}, 'audio':audio})
    if expected != exam['revision']:
        raise ExamError('EXAM_REVISION_MISMATCH')
    return {'section_count':len(exam['sections']), 'task_count':sum(len(s['tasks']) for s in exam['sections']),
            'item_count':sum(len(t['items']) for s in exam['sections'] for t in s['tasks'])}


def validate_audio(audio, exam):
    original = next(s for s in exam['sources'] if s['id']=='audio')
    if not isinstance(audio,dict) or audio.get('source',{}).get('sha256')!=original['sha256']:
        raise ExamError('EXAM_AUDIO_SOURCE_MISMATCH')
    duration = audio['source'].get('duration_ms')
    if type(duration) is not int or duration <= 0:
        raise ExamError('INVALID_EXAM_AUDIO_DURATION')
    expected = {t['label'] for s in exam['sections'] if s['id']=='listening' for t in s['tasks']}
    tasks = audio.get('tasks',[])
    if len(tasks)!=len(expected) or {t.get('task_label') for t in tasks}!=expected:
        raise ExamError('INVALID_EXAM_AUDIO_TASKS')
    previous_end = 0
    for task in tasks:
        if not task.get('occurrences'):
            raise ExamError('MISSING_EXAM_AUDIO_OCCURRENCE')
        for occurrence in task['occurrences']:
            start,end = occurrence.get('start_ms'),occurrence.get('end_ms')
            if type(start) is not int or type(end) is not int or not previous_end <= start < end <= duration:
                raise ExamError('INVALID_EXAM_AUDIO_INTERVAL')
            previous_end=end


def validate_package(root):
    root = Path(root).resolve()
    try:
        if any(path.is_symlink() for path in root.rglob('*')):
            raise ExamError('EXAM_SYMLINK_NOT_ALLOWED')
        manifest = load_json(safe_file(root,'artifact-manifest.json'))
        exam = load_json(safe_file(root,'exam.json'))
        audio_path = safe_file(root,'audio.json')
        audio = load_json(audio_path) if audio_path.exists() else None
        rows = manifest.get('artifacts')
        if not isinstance(rows,list) or not rows or len(rows)>10000:
            raise ExamError('INVALID_EXAM_ARTIFACT_MANIFEST')
        listed = set()
        for row in rows:
            relative = row.get('path')
            path = safe_file(root,relative)
            if (relative in listed or relative=='artifact-manifest.json' or not path.is_file()
                    or type(row.get('bytes')) is not int or row['bytes']<=0
                    or path.stat().st_size != row['bytes'] or file_digest(path)!=row.get('sha256')):
                raise ExamError('EXAM_ARTIFACT_MISMATCH', details={'path':relative})
            if not row.get('source_refs'):
                raise ExamError('MISSING_ARTIFACT_PROVENANCE')
            listed.add(relative)
        actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and p!=root/'artifact-manifest.json'}
        if actual!=listed:
            raise ExamError('UNLISTED_EXAM_ARTIFACT')
        for source in exam['sources']:
            path = safe_file(root,source['path'])
            if (source['path'] not in listed or path.stat().st_size!=source['bytes'] or file_digest(path)!=source['sha256']):
                raise ExamError('EXAM_ORIGINAL_MISMATCH')
        if manifest.get('exam_id')!=exam['id'] or manifest.get('revision')!=exam['revision']:
            raise ExamError('EXAM_MANIFEST_REVISION_MISMATCH')
        summary = validate_exam(exam,audio)
        source_map = {s['id']:s for s in exam['sources']}
        for row in rows:
            for ref in row['source_refs']:
                source = source_map.get(ref.get('source_id'))
                if (not source or ('sha256' in ref and ref['sha256']!=source['sha256'])
                        or ('url' in ref and ref['url']!=source['url'])):
                    raise ExamError('ARTIFACT_ORIGINAL_BINDING_MISMATCH')
        return {'exam':exam,'audio':audio,'manifest':manifest,
                'manifest_digest':fingerprint(manifest),'content_digest':exam['revision'],'summary':summary}
    except ExamError:
        raise
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ExamError('INVALID_EXAM_PACKAGE', details={'issue':str(error)[:500]}) from None


def pick(node, fields):
    return {key:copy.deepcopy(node[key]) for key in fields if key in node}


def public_refs(refs):
    return [pick(ref,('source_id','page','start_ms','end_ms')) for ref in refs if ref.get('source_id') in PUBLIC_SOURCES]


def public_presentation(presentation):
    result = pick(presentation,('layout','columns','show_example_in_table','example_answer',
        'answer_label','option_bank','input_format','example_option_ids','suppress_example_blocks',
        'bank_position','display_codes','source_column_headers'))
    result['source_refs']=public_refs(presentation.get('source_refs',[]))
    if 'rows' in presentation:
        result['rows']=[]
        for row in presentation['rows']:
            public = pick(row,('label','left','right_label','right','right_option_id','source_right_label',
                             'left_item_id','item_id','statement','underlined_text','question_template',
                             'answer_line','required_word'))
            public['source_refs']=public_refs(row.get('source_refs',[]))
            result['rows'].append(public)
    return result


def source_download_path(exam_id,revision,source_id):
    return f'/v1/exams/{quote(exam_id,safe="")}/revisions/{quote(revision,safe="")}/sources/{source_id}/content'


def student_projection(exam):
    result = pick(exam,('schema_version','id','revision','title','language','level','audience','session','interactive_section_ids'))
    result['sources']=[]
    for source in exam['sources']:
        if source['id'] in PUBLIC_SOURCES:
            row=pick(source,('id','url','path','sha256','bytes','media_type','page_count'))
            row['download_path']=source_download_path(exam['id'],exam['revision'],source['id'])
            result['sources'].append(row)
    result['sections']=[]
    for section in exam['sections']:
        public = pick(section,('id','title','position','time_limit_seconds','max_score_units','status','selection'))
        public['source_refs']=public_refs(section.get('source_refs',[]))
        public['tasks']=[]
        for task in section['tasks']:
            out=pick(task,('id','label','position','title','instruction','interaction_type','max_score_units'))
            out['source_refs']=public_refs(task.get('source_refs',[]))
            if 'presentation' in task:
                out['presentation']=public_presentation(task['presentation'])
            out['blocks']=[]
            for block in task['blocks']:
                node=pick(block,('id','type','text','underlined_text','is_scored'))
                if block['type']=='example' and block.get('is_scored') is False and 'answer' in block:
                    node['answer']=copy.deepcopy(block['answer'])
                node['source_refs']=public_refs(block.get('source_refs',[]))
                out['blocks'].append(node)
            out['options']=[]
            for option in task['options']:
                node=pick(option,('id','label','text'))
                node['source_refs']=public_refs(option.get('source_refs',[]))
                out['options'].append(node)
            out['items']=[]
            for item in task['items']:
                node=pick(item,('id','label','position','prompt','response_type','option_ids','max_score_units',
                                'context','underlined_text','required_word','selection'))
                node['source_refs']=public_refs(item.get('source_refs',[]))
                out['items'].append(node)
            public['tasks'].append(out)
        result['sections'].append(public)
    return result


def student_audio(audio):
    if audio is None:
        return None
    result=pick(audio,('schema_version','timestamp_unit','review_status'))
    result['source']=pick(audio['source'],('source_id','sha256','duration_ms'))
    result['tasks']=[{'task_label':t['task_label'],'occurrences':[
        pick(o,('id','source_id','start_ms','end_ms','role','review_status')) for o in t['occurrences']]}
        for t in audio['tasks']]
    return result


def validate_response(item,answer):
    if item['response_type']=='multi_choice':
        if (not isinstance(answer,list) or any(not isinstance(a,str) for a in answer)
                or len(answer)!=len(set(answer)) or len(answer)>128
                or not set(answer).issubset(set(item.get('option_ids',[])))
                or len(answer)>item.get('selection',{}).get('max',128)):
            raise ExamError('INVALID_EXAM_RESPONSE')
    elif not isinstance(answer,str) or len(answer)>8000:
        raise ExamError('INVALID_EXAM_RESPONSE')
    else:
        try: answer.encode('utf-8')
        except UnicodeError: raise ExamError('INVALID_EXAM_RESPONSE') from None
        allowed=item.get('option_ids',[])
        if allowed and answer and answer not in allowed:
            raise ExamError('INVALID_EXAM_RESPONSE_OPTION')
        if item['grading']['mode']=='token_membership':
            if len(tokens(answer,item['grading']))>item['grading'].get('max_tokens',len(item['grading']['accepted_answers'])):
                raise ExamError('TOO_MANY_EXAM_TOKENS')
    return copy.deepcopy(answer)


def grade_sections(exam,responses,section_ids,assessments=None):
    assessments=assessments or {}
    sections=[]
    for section in exam['sections']:
        if section['id'] not in section_ids:
            continue
        items=[]
        objective=0
        pending=False
        task_assessments=[]
        for task in section['tasks']:
            assessment=assessments.get(task['id'])
            has_ai=any(i['grading']['mode']=='ai_stub' for i in task['items'])
            if assessment:
                task_assessments.append(copy.deepcopy(assessment))
            for item in task['items']:
                answer=responses.get(item['id'], [] if item['response_type']=='multi_choice' else '')
                validate_response(item,answer)
                grading=item['grading']; mode=grading['mode']; maximum=item['max_score_units']
                row={'item_id':item['id'],'task_id':task['id'],'max_score_units':maximum}
                if mode in {'ai_stub','manual'}:
                    row.update(status='assessed_at_task_level' if assessment else ('pending_ai' if mode=='ai_stub' else 'pending_manual'),awarded_score_units=None)
                    pending |= assessment is None
                else:
                    if mode=='token_membership':
                        accepted={normalize_token(a,grading) for a in grading['accepted_answers']}; matched=len(tokens(answer,grading)&accepted)
                        score=matched*maximum//len(accepted)
                        row['matched_token_count']=matched
                    elif mode=='set':
                        score=maximum if any(set(answer)==set(a) for a in grading['accepted_answers']) else 0
                    else:
                        normalize=lambda value:unicodedata.normalize('NFC',value).strip().casefold() if grading.get('ignore_case') else unicodedata.normalize('NFC',value).strip()
                        score=maximum if any(normalize(answer)==normalize(a) for a in grading['accepted_answers']) else 0
                    objective+=score
                    row.update(status='correct' if score==maximum else 'partial' if score else 'incorrect',awarded_score_units=score)
                items.append(row)
        total=objective+sum(a['score_units'] for a in task_assessments)
        sections.append({'section_id':section['id'],'status':'pending' if pending else 'graded',
            'score_units':None if pending else total,'objective_score_units':objective,
            'max_score_units':section['max_score_units'],'items':items,'task_assessments':task_assessments})
    return {'exam_id':exam['id'],'revision':exam['revision'],'ai_integration':'pending_or_completed','sections':sections}
