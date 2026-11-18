"""Framework-free domain routing; authenticated transport supplies owner identity."""
from .contract import ExamError
from .service import owner_id


def handle(service,route,owner,body=None,params=None,query=None):
    owner_id(owner)
    params=params or {}; query=query or {}; body=body or {}
    if route=='GET /v1/exams':
        return service.catalog()
    if route=='GET /v1/exams/{id}':
        return service.student_package(params.get('id'))
    if route=='GET /v1/exams/{id}/revisions/{revision}':
        return service.student_package(params.get('id'),params.get('revision'))
    if route=='GET /v1/exams/{id}/revisions/{revision}/sources/{source_id}/download':
        return service.download_metadata(params.get('id'),params.get('revision'),params.get('source_id'))
    if route=='POST /v1/exam-imports/dry-run':
        if not isinstance(body,dict) or set(body)!={'package_dir'}:
            raise ExamError('INVALID_EXAM_REQUEST')
        return service.dry_run(owner,body['package_dir'])
    if route=='POST /v1/exam-imports/{id}/commit':
        if not isinstance(body,dict) or set(body)!={'transaction_id','expected_manifest_digest'}:
            raise ExamError('INVALID_EXAM_REQUEST')
        return service.commit(owner,params.get('id'),body['transaction_id'],body['expected_manifest_digest'])
    if route=='GET /v1/exam-attempts':
        return service.list_attempts(owner)
    if route=='POST /v1/exam-attempts':
        return service.create_attempt(owner,body)
    if route=='GET /v1/exam-attempts/{id}':
        return service.get_attempt(owner,params.get('id'))
    if route=='PUT /v1/exam-attempts/{id}':
        return service.update_attempt(owner,params.get('id'),body)
    if route=='POST /v1/exam-attempts/{id}/submit':
        return service.submit_attempt(owner,params.get('id'),body)
    if route=='GET /v1/exam-attempts/{id}/assessment/{task_id}':
        return service.assessment_input(owner,params.get('id'),params.get('task_id'),query.get('feedback_language','pl'))
    if route=='POST /v1/exam-attempts/{id}/assessment/{task_id}':
        if not isinstance(body,dict) or set(body)!={'result','provenance'}:
            raise ExamError('INVALID_EXAM_REQUEST')
        return service.record_assessment(owner,params.get('id'),params.get('task_id'),body['result'],body['provenance'])
    raise ExamError('NOT_FOUND',404)
