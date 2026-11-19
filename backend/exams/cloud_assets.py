"""Private, version-pinned S3 artifacts. No answer-key asset is signed for students."""
from __future__ import annotations

import base64
import hashlib
import json
import mimetypes

from .contract import ExamError


class CloudAssets:
    def __init__(self, client, bucket, expires_in=900):
        self.client = client
        self.bucket = bucket
        self.expires_in = expires_in

    def _verify_head(self, key, digest, size, version=None):
        params = {'Bucket': self.bucket, 'Key': key, 'ChecksumMode': 'ENABLED'}
        if version:
            params['VersionId'] = version
        head = self.client.head_object(**params)
        checksum = base64.b64encode(bytes.fromhex(digest)).decode('ascii')
        if head['ContentLength'] != size or head.get('ChecksumSHA256') != checksum:
            raise ExamError('IMMUTABLE_EXAM_ASSET_CONFLICT', 409)
        version = head.get('VersionId')
        if not version or version == 'null':
            raise ExamError('EXAMS_BUCKET_VERSIONING_REQUIRED', 503)
        return {'key': key, 'version_id': version, 'sha256': digest, 'bytes': size}

    def put_file(self, key, path, digest, size):
        # SDK validates the supplied checksum against streamed bytes at S3.
        checksum = base64.b64encode(bytes.fromhex(digest)).decode('ascii')
        with path.open('rb') as body:
            try:
                response = self.client.put_object(Bucket=self.bucket, Key=key, Body=body,
                    ContentLength=size, ContentType=mimetypes.guess_type(path.name)[0] or 'application/octet-stream',
                    ServerSideEncryption='AES256', IfNoneMatch='*',
                    ChecksumAlgorithm='SHA256', ChecksumSHA256=checksum,
                    Metadata={'sha256': digest})
            except self.client.exceptions.ClientError as error:
                # S3's conditional HTTP errors have no dedicated modeled class.
                if error.response.get('ResponseMetadata', {}).get('HTTPStatusCode') != 412:
                    raise
                return self._verify_head(key, digest, size)
        return self._verify_head(key, digest, size, response.get('VersionId'))

    def json(self, descriptor):
        if descriptor['bytes'] > 16 * 1024 * 1024:
            raise ExamError('EXAM_METADATA_TOO_LARGE', 413)
        response = self.client.get_object(Bucket=self.bucket, Key=descriptor['key'],
                                          VersionId=descriptor['version_id'])
        with response['Body'] as body:
            raw = body.read(16 * 1024 * 1024 + 1)
        if len(raw) != descriptor['bytes'] or hashlib.sha256(raw).hexdigest() != descriptor['sha256']:
            raise ExamError('EXAM_ASSET_DAMAGED', 503)
        try:
            return json.loads(raw)
        except (ValueError, UnicodeError):
            raise ExamError('EXAM_ASSET_DAMAGED', 503) from None

    def download(self, descriptor, media_type):
        self._verify_head(descriptor['key'], descriptor['sha256'], descriptor['bytes'], descriptor['version_id'])
        url = self.client.generate_presigned_url('get_object', Params={
            'Bucket': self.bucket, 'Key': descriptor['key'], 'VersionId': descriptor['version_id'],
            'ResponseContentType': media_type}, ExpiresIn=self.expires_in)
        return {'bytes': int(descriptor['bytes']), 'sha256': descriptor['sha256'],
                'media_type': media_type, 'download_url': url, 'expires_in': self.expires_in}
