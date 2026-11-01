import json
import os
import boto3
from backend.billing import runtime as billing_runtime
from .repository import Repository
from .service import TranslationService
from .policy import Policy
from .provider import OpenAIProvider


def policy():
    return Policy.load(os.environ['CLOUD_POLICY'], os.environ.get('ACCEPT_TRANSLATIONS') == 'true',
                       os.environ.get('ACCEPT_ALIGNMENTS') == 'true')


def service(provider=False):
    repo = Repository(boto3.client('dynamodb'), os.environ['TRANSLATION_REQUESTS_TABLE'],
        os.environ['TRANSLATION_CONTENTS_TABLE'], os.environ['USAGE_TABLE'],
        os.environ['ACCOUNTS_TABLE'], os.environ['SUBSCRIPTIONS_TABLE'])
    external = None
    if provider:
        secret = json.loads(boto3.client('secretsmanager').get_secret_value(SecretId=os.environ['OPENAI_SECRET_ARN'])['SecretString'])
        external = OpenAIProvider(secret['api_key'])
    return TranslationService(repo, billing_runtime.repository(), policy(), external)
