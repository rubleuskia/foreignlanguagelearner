#!/usr/bin/env python3
"""Local Cognito login; passwords are prompted, only the short-lived access token is saved."""
import argparse
import getpass
import os
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-id', required=True, help='ClientId output of the operator stack')
    parser.add_argument('--username', default='operator')
    parser.add_argument('--output', required=True, type=Path, help='New private access-token file')
    args = parser.parse_args()
    import boto3
    from botocore import UNSIGNED
    from botocore.config import Config
    client = boto3.client('cognito-idp', region_name='eu-north-1',
        config=Config(signature_version=UNSIGNED, connect_timeout=5, read_timeout=15,
                      retries={'total_max_attempts': 1}))
    value = client.initiate_auth(ClientId=args.client_id, AuthFlow='USER_PASSWORD_AUTH',
        AuthParameters={'USERNAME': args.username, 'PASSWORD': getpass.getpass('Password: ')})
    if value.get('ChallengeName') == 'NEW_PASSWORD_REQUIRED':
        password = getpass.getpass('New permanent password: ')
        if password != getpass.getpass('Repeat new password: '):
            raise ValueError('Passwords do not match')
        value = client.respond_to_auth_challenge(ClientId=args.client_id, ChallengeName='NEW_PASSWORD_REQUIRED',
            Session=value['Session'], ChallengeResponses={'USERNAME': args.username, 'NEW_PASSWORD': password})
    if 'AuthenticationResult' not in value:
        raise ValueError('Complete the required Cognito challenge in your configured login client')
    # Do not persist ID/refresh tokens or password. The output path is created exclusively, mode 600.
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(value['AuthenticationResult']['AccessToken'])
    print('Access token saved to:', args.output.resolve())
    print('Expires in seconds:', value['AuthenticationResult'].get('ExpiresIn', 900))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never print raw SDK messages, challenge payloads or token values.
        print('Login failed:', type(error).__name__, file=sys.stderr)
        sys.exit(1)
