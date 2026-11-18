"""Server-owned assessment preparation; student payloads cannot replace a rubric."""
from backend.cloud.errors import CloudError
from backend.translation.contract import inference_settings
from .assessment_contract import (build_grading_request, compile_assessment,
                                 validate_assessment_result, InvalidAssessment, fingerprint)


def prepare(service, owner, value):
    allowed = {'attempt_id', 'task_id', 'feedback_language', 'model', 'reasoning_effort'}
    if (not isinstance(value, dict) or set(value) - allowed
            or not {'attempt_id', 'task_id', 'model', 'reasoning_effort'}.issubset(value)):
        raise CloudError('INVALID_REQUEST')
    for key in ('attempt_id', 'task_id'):
        if not isinstance(value[key], str) or not 1 <= len(value[key]) <= 160:
            raise CloudError('INVALID_REQUEST')
    inference_settings(value)
    context = service.assessment_context(owner, value['attempt_id'], value['task_id'])
    exam = context['exam']
    try:
        request = build_grading_request(exam, value['task_id'], context['responses'],
                                       value.get('feedback_language', 'pl'))
        contract = compile_assessment(context['task'], exam['id'])
    except InvalidAssessment:
        raise CloudError('INVALID_ASSESSMENT') from None
    return {'schema_version': 1, 'attempt_id': value['attempt_id'],
            'task_id': value['task_id'], 'model': value['model'],
            'reasoning_effort': value['reasoning_effort'],
            'assessment_request': request, 'assessment_contract': contract}


def validate_prepared(value):
    if (not isinstance(value, dict) or set(value) != {
            'schema_version', 'attempt_id', 'task_id', 'model', 'reasoning_effort',
            'assessment_request', 'assessment_contract'} or value['schema_version'] != 1):
        raise CloudError('INVALID_REQUEST')
    inference_settings(value)
    try:
        contract = value['assessment_contract']
        validate_assessment_result(contract, {'score_units': 0, 'rationale': 'Validation'})
        request = value['assessment_request']
        if (request['contract_sha256'] != contract['contract_sha256']
                or request['task_id'] != value['task_id']
                or request['request_sha256'] != fingerprint({k: v for k, v in request.items() if k != 'request_sha256'})
                or request['provider_body_template']['text']['format'] != contract['response_format']):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise CloudError('INVALID_ASSESSMENT') from None
    return value


def validate_result(value, payload):
    try:
        return validate_assessment_result(payload['assessment_contract'], value)
    except (KeyError, InvalidAssessment):
        raise CloudError('INVALID_OUTPUT') from None
