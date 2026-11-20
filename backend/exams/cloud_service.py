"""Exam domain on DynamoDB and private versioned S3; no ephemeral database fallback."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import time
import uuid

from backend.translation.contract import inference_settings
from .assessment_contract import compile_assessment, validate_assessment_result
from .cloud_assets import CloudAssets
from .cloud_repository import CloudRepository, ConcurrentWrite, owner_partition
from .contract import (ExamError, PUBLIC_SOURCES, canonical, fingerprint, file_digest,
                       identity, safe_file, student_projection, student_audio, validate_package)
from .service import Service, fields, iso, owner_id, uid


def preview(package_dir):
    """Read-only validation: no AWS client, upload or database write."""
    package = validate_package(package_dir)
    return {'exam_id': package['exam']['id'], 'revision': package['exam']['revision'],
            'manifest_digest': package['manifest_digest'], 'content_digest': package['content_digest'],
            'summary': package['summary'], 'action': 'validate_only', 'errors': [],
            'warnings': ['Machine audio ranges retain their review state. Publication requires explicit commit.']}


class CloudService(Service):
    def __init__(self, repository, assets, now=time.time):
        self.repository = repository
        self.assets = assets
        self.now = now

    @classmethod
    def configured(cls, table_name, bucket, *, region=None, profile=None):
        import boto3
        from botocore.config import Config
        session = boto3.Session(region_name=region, profile_name=profile)
        config = Config(retries={'mode': 'standard', 'total_max_attempts': 4},
                        connect_timeout=5, read_timeout=30)
        table = session.resource('dynamodb', config=config).Table(table_name)
        s3 = session.client('s3', config=Config(signature_version='s3v4',
            retries={'mode': 'standard', 'total_max_attempts': 4}, connect_timeout=5, read_timeout=60))
        return cls(CloudRepository(table), CloudAssets(s3, bucket))

    def dry_run(self, owner, package_dir):
        raise ExamError('EXAM_CLOUD_IMPORT_REQUIRES_ADMIN_CLI', 403)

    def commit(self, owner, import_id, transaction_id, expected_manifest_digest):
        raise ExamError('EXAM_CLOUD_IMPORT_REQUIRES_ADMIN_CLI', 403)

    def _revision(self, connection, exam_id, revision=None):
        identity(exam_id)
        if revision is None:
            pointer = self.repository.get('CATALOG', 'EXAM#' + exam_id)
            if not pointer:
                raise ExamError('EXAM_NOT_FOUND', 404)
            revision = pointer['revision']
        if not isinstance(revision, str) or not re.fullmatch('[a-f0-9]{64}', revision):
            raise ExamError('INVALID_EXAM_REVISION')
        row = self.repository.get('EXAM#' + exam_id, 'REV#' + revision)
        if not row:
            raise ExamError('EXAM_NOT_FOUND', 404)
        exam = self.assets.json(row['exam_object'])
        audio = self.assets.json(row['audio_object']) if row.get('audio_object') else None
        if (exam.get('id') != exam_id or exam.get('revision') != revision
                or fingerprint({'exam': {k: v for k, v in exam.items() if k != 'revision'}, 'audio': audio}) != revision):
            raise ExamError('EXAM_ASSET_DAMAGED', 503)
        return row, exam, audio

    @staticmethod
    def _catalog_entry(exam):
        return {k: copy.deepcopy(exam[k]) for k in
                ('id', 'revision', 'title', 'language', 'level', 'audience', 'session', 'interactive_section_ids')} | {
            'sections': [{k: s[k] for k in ('id', 'title', 'status', 'max_score_units', 'time_limit_seconds') if k in s}
                         for s in exam['sections']],
            'download_bytes': sum(s['bytes'] for s in exam['sources'] if s['id'] in PUBLIC_SOURCES)}

    def catalog(self):
        return {'schema_version': '1.1', 'exams': [json.loads(row['summary_json'])
                for row in self.repository.query('CATALOG', 'EXAM#') if row.get('active') is True]}

    def _require_active_exam(self, exam_id):
        identity(exam_id)
        pointer = self.repository.get('CATALOG', 'EXAM#' + exam_id)
        if not pointer or pointer.get('active') is not True:
            raise ExamError('EXAM_NOT_FOUND', 404)
        return pointer

    def set_active(self, exam_id, active):
        """Administrator SDK operation, deliberately absent from student routes."""
        from boto3.dynamodb.conditions import Attr
        identity(exam_id)
        if type(active) is not bool:
            raise ExamError('INVALID_EXAM_ACTIVE')
        for _ in range(8):
            old = self.repository.get('CATALOG', 'EXAM#' + exam_id)
            if not old:
                raise ExamError('EXAM_NOT_FOUND', 404)
            condition = Attr('revision').eq(old['revision']) & self._active_condition(old)
            updated = {**old, 'active': active}
            try:
                self.repository.transaction([(updated, condition)])
                return {'exam_id': exam_id, 'revision': old['revision'], 'active': active}
            except ConcurrentWrite:
                continue
        raise ExamError('EXAM_CATALOG_CONFLICT', 409)

    @staticmethod
    def _active_condition(row):
        from boto3.dynamodb.conditions import Attr
        return Attr('active').eq(row['active']) if 'active' in row else Attr('active').not_exists()

    def student_package(self, exam_id, revision=None):
        self._require_active_exam(exam_id)
        row, exam, audio = self._revision(None, exam_id, revision)
        public = student_projection(exam)
        for source in public['sources']:
            source.pop('download_path', None)
            source.update(self._download(row, exam, source['id']))
        return {'schema_version': '1.1', 'exam': public, 'audio': student_audio(audio)}

    def _download(self, row, exam, source_id):
        if source_id not in PUBLIC_SOURCES:
            raise ExamError('EXAM_SOURCE_NOT_FOUND', 404)
        source = next((s for s in exam['sources'] if s['id'] == source_id), None)
        if not source or source_id not in row['public_assets']:
            raise ExamError('EXAM_SOURCE_NOT_FOUND', 404)
        return self.assets.download(row['public_assets'][source_id], source['media_type'])

    def download_metadata(self, exam_id, revision, source_id):
        self._require_active_exam(exam_id)
        if source_id not in PUBLIC_SOURCES:
            raise ExamError('EXAM_SOURCE_NOT_FOUND', 404)
        row, exam, _ = self._revision(None, exam_id, revision)
        return self._download(row, exam, source_id)

    def resolve_asset(self, exam_id, revision, source_id):
        return self.download_metadata(exam_id, revision, source_id)

    def publish(self, owner, package_dir, transaction_id, expected_manifest_digest):
        """Administrator-only SDK entry point; not exposed by HTTP routes."""
        from boto3.dynamodb.conditions import Attr
        owner = owner_id(owner); transaction_id = uid(transaction_id)
        package = validate_package(package_dir)
        if package['manifest_digest'] != expected_manifest_digest:
            raise ExamError('EXAM_IMPORT_DIGEST_CONFLICT', 409)
        pk = owner_partition(owner); sk = 'IMPORT_TX#' + transaction_id
        exam = package['exam']; revision = exam['revision']; exam_id = exam['id']
        import_id = str(uuid.uuid5(uuid.NAMESPACE_URL, pk + ':' + transaction_id))
        uploaded = None
        for _ in range(8):
            prior = self.repository.get(pk, sk)
            if prior:
                if prior['manifest_digest'] != expected_manifest_digest or prior['exam_id'] != exam_id:
                    raise ExamError('IMPORT_TRANSACTION_CONFLICT', 409)
                return json.loads(prior['result_json'])
            existing = self.repository.get('EXAM#' + exam_id, 'REV#' + revision)
            if not existing and uploaded is None:
                prefix = f'exams/{exam_id}/{revision}/{expected_manifest_digest}/'
                artifacts = {}
                rows = package['manifest']['artifacts'] + [{'path': 'artifact-manifest.json',
                    'sha256': file_digest(Path(package_dir) / 'artifact-manifest.json'),
                    'bytes': (Path(package_dir) / 'artifact-manifest.json').stat().st_size}]
                for artifact in rows:
                    path = safe_file(package_dir, artifact['path'])
                    artifacts[artifact['path']] = self.assets.put_file(prefix + artifact['path'],
                        path, artifact['sha256'], artifact['bytes'])
                checked = validate_package(package_dir)
                if checked['manifest_digest'] != expected_manifest_digest:
                    raise ExamError('EXAM_PACKAGE_CHANGED_DURING_IMPORT', 409)
                uploaded = {'pk': 'EXAM#' + exam_id, 'sk': 'REV#' + revision,
                    'exam_id': exam_id, 'revision': revision, 'manifest_digest': expected_manifest_digest,
                    'exam_object': artifacts['exam.json'], 'audio_object': artifacts.get('audio.json'),
                    'manifest_object': artifacts['artifact-manifest.json'],
                    'public_assets': {s['id']: artifacts[s['path']] for s in exam['sources'] if s['id'] in PUBLIC_SOURCES},
                    'created_at': iso(self.now())}
            result = {'import_id': import_id, 'exam_id': exam_id, 'revision': revision,
                      'manifest_digest': expected_manifest_digest, 'state': 'committed', 'content_unchanged': bool(existing)}
            transaction = {'pk': pk, 'sk': sk, 'owner': owner, 'exam_id': exam_id,
                           'manifest_digest': expected_manifest_digest, 'result_json': canonical(result)}
            rows = [(transaction, Attr('pk').not_exists())]
            if not existing:
                old = self.repository.get('CATALOG', 'EXAM#' + exam_id)
                condition = (Attr('revision').eq(old['revision']) & self._active_condition(old)) if old else Attr('pk').not_exists()
                catalog = {'pk': 'CATALOG', 'sk': 'EXAM#' + exam_id, 'revision': revision,
                           'summary_json': canonical(self._catalog_entry(exam)),
                           'active': old.get('active') is True if old else False}
                rows += [(uploaded, Attr('pk').not_exists()), (catalog, condition)]
            try:
                self.repository.transaction(rows)
                return result
            except ConcurrentWrite:
                continue
        raise ExamError('EXAM_IMPORT_CONFLICT', 409)

    def _attempt_row(self, owner, data):
        return {'pk': owner_partition(owner), 'sk': 'ATTEMPT#' + data['id'], 'owner': owner,
                'version': data['version'], 'updated_at': data['updated_at'], 'data_json': canonical(data)}

    def _read_attempt(self, owner, attempt_id):
        row = self.repository.get(owner_partition(owner), 'ATTEMPT#' + attempt_id)
        if not row or row['owner'] != owner:
            raise ExamError('EXAM_ATTEMPT_NOT_FOUND', 404)
        return json.loads(row['data_json'])

    def create_attempt(self, owner, payload):
        owner = owner_id(owner)
        fields(payload, {'attempt_id','exam_id','revision','mode','device_id','section_ids'},
               {'attempt_id','exam_id','revision','mode','device_id'})
        attempt_id = uid(payload['attempt_id']); device = identity(payload['device_id'])
        if not isinstance(payload['mode'], str) or payload['mode'] not in {'exam','training'}:
            raise ExamError('INVALID_EXAM_MODE')
        self._require_active_exam(payload['exam_id'])
        _, exam, _ = self._revision(None, payload['exam_id'], payload['revision'])
        selected = payload.get('section_ids', exam['interactive_section_ids'])
        if (not isinstance(selected, list) or not selected or any(not isinstance(s, str) for s in selected)
                or len(selected) != len(set(selected)) or not set(selected).issubset(exam['interactive_section_ids'])):
            raise ExamError('INVALID_EXAM_SECTION_SELECTION')
        initial = fingerprint({'exam_id': exam['id'], 'revision': exam['revision'], 'mode': payload['mode'], 'section_ids': selected})
        data = self._new_attempt(owner, attempt_id, device, exam, selected, payload['mode'], initial)
        try:
            self.repository.new(self._attempt_row(owner, data))
            return self._snapshot(data)
        except ConcurrentWrite:
            prior = self.get_attempt(owner, attempt_id)
            saved = self._read_attempt(owner, attempt_id)
            if saved['creation_fingerprint'] != initial:
                raise ExamError('EXAM_ATTEMPT_ID_CONFLICT', 409)
            return prior

    def get_attempt(self, owner, attempt_id):
        owner = owner_id(owner); attempt_id = uid(attempt_id)
        for _ in range(8):
            data = self._read_attempt(owner, attempt_id)
            _, exam, _ = self._revision(None, data['exam_id'], data['revision'])
            version = data['version']
            if not self._expire_data(data, exam):
                return self._snapshot(data)
            try:
                self.repository.replace_attempt(self._attempt_row(owner, data), version)
                return self._snapshot(data)
            except ConcurrentWrite:
                continue
        raise ExamError('EXAM_ATTEMPT_CONFLICT', 409)

    def list_attempts(self, owner):
        owner = owner_id(owner)
        rows = list(self.repository.query(owner_partition(owner), 'ATTEMPT#'))
        rows.sort(key=lambda row: row['sk'])
        rows.sort(key=lambda row: row['updated_at'], reverse=True)
        return {'attempts': [self.get_attempt(owner, row['sk'].removeprefix('ATTEMPT#')) for row in rows]}

    def _mutate(self, owner, attempt_id, payload, submit):
        from boto3.dynamodb.conditions import Attr
        owner = owner_id(owner); attempt_id = uid(attempt_id)
        allowed = {'base_version','change_id','device_id','section_id','takeover'} if submit else {
            'base_version','change_id','device_id','responses','progress','state','takeover'}
        fields(payload, allowed, {'base_version','change_id','device_id'})
        change_id = uid(payload['change_id']); device = identity(payload['device_id'])
        if type(payload['base_version']) is not int or payload['base_version'] < 1:
            raise ExamError('INVALID_ATTEMPT_VERSION')
        if 'takeover' in payload and type(payload['takeover']) is not bool:
            raise ExamError('INVALID_EXAM_TAKEOVER')
        try:
            digest = fingerprint({'operation': 'submit' if submit else 'update', 'payload': payload})
        except (ValueError, TypeError, UnicodeError):
            raise ExamError('INVALID_EXAM_REQUEST') from None
        pk = owner_partition(owner); sk = f'CHANGE#{attempt_id}#{change_id}'
        for _ in range(8):
            self.get_attempt(owner, attempt_id)  # Persist deadline transitions before rejecting a late request.
            data = self._read_attempt(owner, attempt_id)
            prior = self.repository.get(pk, sk)
            if prior:
                if prior['request_digest'] != digest:
                    raise ExamError('EXAM_CHANGE_ID_CONFLICT', 409)
                return self.get_attempt(owner, attempt_id)
            _, exam, audio = self._revision(None, data['exam_id'], data['revision'])
            changed = self._change_data(data, exam, audio, payload, submit, device)
            record = {'pk': pk, 'sk': sk, 'owner': owner, 'request_digest': digest}
            try:
                self.repository.transaction([
                    (self._attempt_row(owner, changed), Attr('version').eq(data['version']) & Attr('owner').eq(owner)),
                    (record, Attr('pk').not_exists())])
                return self._snapshot(changed)
            except ConcurrentWrite:
                continue
        raise ExamError('EXAM_ATTEMPT_CONFLICT', 409)

    def assessment_context(self, owner, attempt_id, task_id):
        data = self.get_attempt(owner, attempt_id)
        _, exam, _ = self._revision(None, data['exam_id'], data['revision'])
        return self._assessment_context(data, exam, task_id)

    def record_assessment(self, owner, attempt_id, task_id, result, provenance, *, server_verified=False):
        owner = owner_id(owner); attempt_id = uid(attempt_id)
        fields(provenance, {'provider','mode','model','reasoning_effort','revision','contract_sha256',
                           'request_id','request_sha256','prompt_version'},
               {'provider','mode','model','reasoning_effort','revision','contract_sha256'})
        if provenance['provider'] != 'openai' or provenance['mode'] not in {'personalKey','subscription','operator'}:
            raise ExamError('INVALID_EXAM_ASSESSMENT_PROVENANCE')
        if not server_verified and provenance['mode'] != 'personalKey':
            raise ExamError('UNVERIFIED_SERVER_ASSESSMENT', 403)
        inference_settings(provenance)
        if any(not isinstance(v, str) or len(v) > 500 for v in provenance.values()):
            raise ExamError('INVALID_EXAM_ASSESSMENT_PROVENANCE')
        for _ in range(8):
            data = self._read_attempt(owner, attempt_id)
            _, exam, _ = self._revision(None, data['exam_id'], data['revision'])
            context = self._assessment_context(data, exam, task_id)
            contract = compile_assessment(context['task'], exam['id'])
            if provenance['revision'] != data['revision'] or provenance['contract_sha256'] != contract['contract_sha256']:
                raise ExamError('EXAM_ASSESSMENT_REVISION_CONFLICT', 409)
            try:
                value = validate_assessment_result(contract, result)
            except ValueError:
                raise ExamError('INVALID_EXAM_ASSESSMENT_RESULT') from None
            record = {'task_id': task_id, **value, 'origin': 'server_provider' if server_verified else 'client_personal_key',
                      'provenance': copy.deepcopy(provenance), 'source_refs': contract['source_refs']}
            prior = data['assessments'].get(task_id)
            if prior:
                if prior != record:
                    raise ExamError('EXAM_ASSESSMENT_ALREADY_RECORDED', 409)
                return self._snapshot(data)
            version = data['version']
            data['assessments'][task_id] = record; data['version'] += 1; data['updated_at'] = iso(self.now())
            self._refresh_result(data, exam)
            try:
                self.repository.replace_attempt(self._attempt_row(owner, data), version)
                return self._snapshot(data)
            except ConcurrentWrite:
                continue
        raise ExamError('EXAM_ATTEMPT_CONFLICT', 409)
