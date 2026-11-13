"""Serial SQS consumer. Compute runs in a child so lease loss stops inference."""
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import queue
import signal
import tempfile
import time

from backend.book_alignment.contract import ARCHIVE_LIMIT, SYSTEM_OWNER, TERMINAL
from backend.book_alignment.repository import Repository
from book_processing import process


def compute(source, root, job, model_dir, messages):
    try:
        result, review = process(Path(source), Path(root), job, model_dir,
                                 lambda status, progress: messages.put(('stage', status, progress)))
    except Exception as error:
        code = str(error) if str(error) in {'INVALID_TEXT', 'INVALID_AUDIO', 'INVALID_ARCHIVE',
            'INPUT_TOO_LARGE', 'INVALID_TIMINGS'} else 'ALIGNMENT_FAILED'
        messages.put(('error', code))
        return
    try:
        import boto3
        from botocore.config import Config
        messages.put(('stage', 'publishing', 95))
        sha = hashlib.sha256()
        with result.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                sha.update(block)
        client = boto3.client('s3', config=Config(connect_timeout=5, read_timeout=30,
            retries={'total_max_attempts': 3, 'mode': 'standard'}))
        with result.open('rb') as stream:
            published = client.put_object(Bucket=job['bucket'], Key=job['result_key'], Body=stream,
                ContentType='application/zip', ServerSideEncryption='AES256')
        messages.put(('result', {'key': job['result_key'], 'version_id': published['VersionId'],
                                 'bytes': result.stat().st_size, 'sha256': sha.hexdigest()}, review))
    except Exception:
        messages.put(('retry', 'INFRASTRUCTURE_FAILURE'))


class Consumer:
    def __init__(self, repository, s3, sqs, bucket, queue_url, model_dir):
        self.repo, self.s3, self.sqs = repository, s3, sqs
        self.bucket, self.queue_url, self.model_dir = bucket, queue_url, model_dir

    def ack(self, message):
        self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=message['ReceiptHandle'])

    def handle(self, message):
        pointer = json.loads(message['Body'])
        if pointer.get('owner') != SYSTEM_OWNER or pointer.get('bucket') != self.bucket:
            raise ValueError('Invalid queue pointer')
        row = self.repo.get(pointer['owner'], pointer['job_id'])
        if row['status'] in TERMINAL:
            self.ack(message)
            return
        expected_key = f"books/{row['owner']}/{row['job_id']}/input.zip"
        if pointer.get('key') != expected_key or pointer.get('version_id') != row.get('input_version'):
            raise ValueError('Invalid queue input identity')
        row = self.repo.claim(row['owner'], row['job_id'], int(time.time()))
        if row is None:
            self.ack(message)  # Lease recovery is durable in DynamoDB, independent of SQS visibility.
            return  # The periodic dispatcher restores expired leases.
        self.ack(message)
        child = None
        try:
            with tempfile.TemporaryDirectory(prefix='book-alignment-') as directory:
                root = Path(directory)
                source = root / 'input.zip'
                head = self.s3.head_object(Bucket=self.bucket, Key=expected_key, VersionId=row['input_version'])
                if not 0 < head['ContentLength'] <= ARCHIVE_LIMIT or head['ContentLength'] != row['size_bytes']:
                    raise ValueError('INPUT_TOO_LARGE')
                digest = hashlib.sha256()
                last_heartbeat = time.monotonic()
                incoming = self.s3.get_object(Bucket=self.bucket, Key=expected_key,
                                              VersionId=row['input_version'])['Body']
                with incoming, source.open('wb') as output:
                    count = 0
                    for block in incoming.iter_chunks(1024 * 1024):
                        count += len(block)
                        if count > ARCHIVE_LIMIT:
                            raise ValueError('INPUT_TOO_LARGE')
                        output.write(block); digest.update(block)
                        if time.monotonic() - last_heartbeat > 20:
                            self.heartbeat(row, message); last_heartbeat = time.monotonic()
                if count != row['size_bytes'] or digest.hexdigest() != row['sha256']:
                    raise ValueError('CHECKSUM_MISMATCH')
                context = multiprocessing.get_context('spawn')
                messages = context.Queue()
                # Decimal-free child inputs; AWS clients stay in the parent.
                job = {key: row[key] for key in ('title', 'language')}
                job.update(bucket=self.bucket,
                    result_key=f"books/{row['owner']}/{row['job_id']}/{row['lease_token']}/book.book.zip")
                child = context.Process(target=compute, args=(str(source), str(root), job, self.model_dir, messages))
                child.start()
                result = None
                while result is None:
                    self.heartbeat(row, message)
                    try:
                        item = messages.get(timeout=20)
                    except queue.Empty:
                        if not child.is_alive():
                            raise RuntimeError('Worker process exited')
                        continue
                    if item[0] == 'stage':
                        row = self.repo.change(row, item[1], item[2], lease_until=int(time.time()) + 180)
                    elif item[0] == 'error':
                        raise ValueError(item[1])
                    elif item[0] == 'retry':
                        raise RuntimeError(item[1])
                    else:
                        result, review = item[1], item[2]
                child.join(timeout=5)
                self.repo.change(row, 'succeeded_with_review' if review else 'succeeded', 100,
                                 result=result, requires_review=review, lease_until=0)
        except ValueError as error:
            code = str(error) if str(error) in {'INPUT_TOO_LARGE', 'CHECKSUM_MISMATCH', 'INVALID_TEXT',
                'INVALID_AUDIO', 'INVALID_ARCHIVE', 'INVALID_TIMINGS', 'ALIGNMENT_FAILED'} else 'INVALID_ARCHIVE'
            self.repo.change(row, 'failed', int(row['progress']), error_code=code, lease_until=0)
        except Exception:
            # Infrastructure failures remain retryable. The lease expires after the process stops.
            if int(row['attempts']) >= 3:
                self.repo.change(row, 'failed', int(row['progress']),
                                 error_code='INFRASTRUCTURE_FAILURE', lease_until=0)
            raise
        finally:
            if child and child.is_alive():
                child.terminate(); child.join(timeout=10)
                if child.is_alive():
                    child.kill(); child.join()

    def heartbeat(self, row, message):
        self.repo.heartbeat(row)


def main():
    import boto3
    from botocore.config import Config
    config = Config(connect_timeout=5, read_timeout=30, retries={'total_max_attempts': 3, 'mode': 'standard'})
    repo = Repository(boto3.resource('dynamodb', config=config).Table(os.environ['BOOK_ALIGNMENT_TABLE']))
    consumer = Consumer(repo, boto3.client('s3', config=config), boto3.client('sqs', config=config),
        os.environ['BOOK_ALIGNMENT_BUCKET'], os.environ['BOOK_ALIGNMENT_QUEUE'], os.environ['MODEL_DIR'])
    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    while True:
        response = consumer.sqs.receive_message(QueueUrl=consumer.queue_url, MaxNumberOfMessages=1,
            WaitTimeSeconds=20, VisibilityTimeout=120)
        for message in response.get('Messages', []):
            try:
                consumer.handle(message)
            except Exception:
                print(json.dumps({'event': 'book_worker_retry'}), flush=True)
    return 0
