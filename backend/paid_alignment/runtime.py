import os
import boto3
from backend.billing import runtime as billing_runtime
from backend.translation.repository import Repository as UsageRepository
from backend.translation.runtime import policy
from backend.alignment.config import Config
from backend.alignment.aws_adapters import S3Store, Workflow
from .repository import PaidRepository
from .service import AccountAlignmentService


def repository(client, table, owner=None):
    usage = UsageRepository(client, '', '', os.environ['USAGE_TABLE'], os.environ['ACCOUNTS_TABLE'], os.environ['SUBSCRIPTIONS_TABLE'])
    return PaidRepository(client, table, usage, billing_runtime.repository(), policy(), owner)


def service(owner):
    config = Config.from_env()
    repo = repository(boto3.client('dynamodb'), config.table_name, owner)
    return AccountAlignmentService(repo, S3Store(boto3.client('s3'), config.bucket_name),
        Workflow(boto3.client('stepfunctions'), boto3.client('ecs'), config.state_machine_arn, config.cluster_arn),
        bucket=config.bucket_name, state_machine_arn=config.state_machine_arn,
        accept_new_jobs=config.accept_new_jobs and repo.policy.alignment_enabled, owner=owner, usage=repo.usage)
