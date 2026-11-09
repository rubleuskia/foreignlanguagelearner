"""Only gateway-validated access tokens of the console-created operator are accepted."""
import os
from backend.cloud.errors import CloudError


def authenticate(event, cognito, repository):
    claims = event.get('requestContext', {}).get('authorizer', {}).get('jwt', {}).get('claims', {})
    if (claims.get('iss') != os.environ['JWT_ISSUER']
            or claims.get('client_id') != os.environ['JWT_CLIENT_ID']
            or claims.get('token_use') != 'access' or not claims.get('sub')
            or 'aws.cognito.signin.user.admin' not in claims.get('scope', '').split()):
        raise CloudError('UNAUTHORIZED', 401)
    headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
    scheme, _, token = headers.get('authorization', '').partition(' ')
    if scheme.lower() != 'bearer' or not token:
        raise CloudError('UNAUTHORIZED', 401)
    try:
        user = cognito.get_user(AccessToken=token)
    except (cognito.exceptions.NotAuthorizedException, cognito.exceptions.UserNotFoundException):
        raise CloudError('SESSION_REVOKED', 401) from None
    attrs = {a['Name']: a['Value'] for a in user['UserAttributes']}
    if attrs.get('sub') != claims['sub'] or user['Username'] != os.environ['OPERATOR_USERNAME']:
        raise CloudError('OPERATOR_REQUIRED', 403)
    # First valid login pins the subject permanently. Recreating the username cannot adopt its data.
    repository.pin_operator(claims['sub'])
    return claims['sub']
