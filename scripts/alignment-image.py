#!/usr/bin/env python3
"""Build the existing pinned audio worker; publish only with explicit --publish."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-image', required=True, help='python@sha256:<reviewed Linux base digest>')
    parser.add_argument('--ffmpeg-version', required=True)
    parser.add_argument('--model-url', required=True, help='Official OpenAI Whisper multilingual base model URL')
    parser.add_argument('--model-sha256', required=True)
    parser.add_argument('--profile', default='fll-control')
    parser.add_argument('--repository', default='fll-alignment-worker')
    parser.add_argument('--publish', action='store_true', help='Push image to the existing ECR repository; incurs AWS storage usage')
    parser.add_argument('--create-repository', action='store_true', help='Create a private ECR repository if absent (with --publish)')
    parser.add_argument('--output', required=True, type=Path, help='New build-provenance JSON file, not a quality acceptance report')
    args = parser.parse_args()
    if not re.fullmatch(r'python@sha256:[a-f0-9]{64}', args.base_image): parser.error('Pin the official Python base image by digest')
    if not re.fullmatch(r'[a-f0-9]{64}', args.model_sha256): parser.error('Pin the model checksum')
    if args.model_url != f'https://openaipublic.azureedge.net/main/whisper/models/{args.model_sha256}/base.pt':
        parser.error('Use the official checksum-addressed multilingual base.pt URL')
    if not re.fullmatch(r'[a-z0-9][a-z0-9._/-]{1,254}', args.repository): parser.error('Invalid ECR repository name')
    if args.output.exists(): parser.error('Choose a new output file')
    root = Path(__file__).resolve().parents[1]
    run = lambda argv, **kwargs: subprocess.run(argv, check=True, cwd=root, **kwargs)
    tag = 'build-' + uuid.uuid4().hex
    local = 'fll-alignment-worker:' + tag
    run(['docker', 'build', '--platform', 'linux/amd64', '-f', 'tools/subtitle-aligner/worker/Dockerfile',
         '--build-arg', 'PYTHON_BASE_IMAGE=' + args.base_image, '--build-arg', 'FFMPEG_VERSION=' + args.ffmpeg_version,
         '--build-arg', 'MODEL_URL=' + args.model_url, '--build-arg', 'MODEL_SHA256=' + args.model_sha256,
         '-t', local, '.'])
    report = {'source_revision': run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip(),
              'dirty_source': bool(run(['git', 'status', '--porcelain'], capture_output=True, text=True).stdout.strip()),
              'base_image': args.base_image, 'ffmpeg_version': args.ffmpeg_version,
              'model_sha256': args.model_sha256, 'local_image': local, 'region': 'eu-north-1'}
    if args.publish:
        import boto3
        from botocore.config import Config
        session = boto3.Session(profile_name=args.profile, region_name='eu-north-1')
        ecr = session.client('ecr', config=Config(connect_timeout=5, read_timeout=30))
        try:
            repository = ecr.describe_repositories(repositoryNames=[args.repository])['repositories'][0]
        except ecr.exceptions.RepositoryNotFoundException:
            if not args.create_repository: raise
            repository = ecr.create_repository(repositoryName=args.repository, imageTagMutability='IMMUTABLE',
                imageScanningConfiguration={'scanOnPush': True}, encryptionConfiguration={'encryptionType': 'AES256'})['repository']
        target = repository['repositoryUri'] + ':' + tag
        run(['docker', 'tag', local, target])
        auth = ecr.get_authorization_token(registryIds=[repository['registryId']])['authorizationData'][0]
        username, password = base64.b64decode(auth['authorizationToken']).decode().split(':', 1)
        host = run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], capture_output=True, text=True).stdout.strip()
        env = {**os.environ, 'DOCKER_HOST': host}; env.pop('DOCKER_CONTEXT', None)
        with tempfile.TemporaryDirectory(prefix='fll-docker-auth-') as directory:
            docker = ['docker', '--config', directory]
            run([*docker, 'login', '--username', username, '--password-stdin', auth['proxyEndpoint']],
                input=password, text=True, env=env, capture_output=True)
            run([*docker, 'push', target], env=env)
        images = ecr.describe_images(repositoryName=args.repository, imageIds=[{'imageTag': tag}])['imageDetails']
        report.update(workerRepositoryName=args.repository, workerImageDigest=images[0]['imageDigest'])
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
    print('Build provenance saved:', args.output.resolve())
    print('Quality/runtime/memory/cost measurements are still required for this exact image.')


if __name__ == '__main__':
    main()
