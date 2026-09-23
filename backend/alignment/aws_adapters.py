"""AWS adapters. Domain code receives these objects through constructor injection."""
from __future__ import annotations

import json
from typing import Any

from .domain import URL_TTL_SECONDS


class S3Store:
    def __init__(self, client: Any, bucket: str):
        self.client = client
        self.bucket = bucket

    def create_audio_upload(self, key: str, sha256: str) -> str:
        response = self.client.create_multipart_upload(
            Bucket=self.bucket,
            Key=key,
            ServerSideEncryption="AES256",
            Metadata={"declared-sha256": sha256},
        )
        return response["UploadId"]

    def upload_part_url(self, key: str, upload_id: str, part_number: int,
                        content_length: int) -> dict[str, Any]:
        return {
            "part_number": part_number,
            "url": self.client.generate_presigned_url(
                "upload_part",
                Params={"Bucket": self.bucket, "Key": key, "UploadId": upload_id,
                        "PartNumber": part_number, "ContentLength": content_length},
                ExpiresIn=URL_TTL_SECONDS,
            ),
            "headers": {"content-length": str(content_length)},
        }

    def text_put_url(self, key: str, sha256: str) -> dict[str, Any]:
        return {
            "url": self.client.generate_presigned_url(
                "put_object",
                Params={"Bucket": self.bucket, "Key": key, "ChecksumSHA256": sha256,
                        "ContentType": "text/plain; charset=utf-8", "ServerSideEncryption": "AES256"},
                ExpiresIn=URL_TTL_SECONDS,
            ),
            "headers": {
                "content-type": "text/plain; charset=utf-8",
                "x-amz-checksum-sha256": sha256,
                "x-amz-server-side-encryption": "AES256",
            },
        }

    def list_parts(self, key: str, upload_id: str) -> list[dict[str, Any]]:
        parts: list[dict[str, Any]] = []
        marker = 0
        while True:
            response = self.client.list_parts(Bucket=self.bucket, Key=key, UploadId=upload_id,
                                              PartNumberMarker=marker)
            parts.extend(response.get("Parts", []))
            if not response.get("IsTruncated"):
                return parts
            marker = response["NextPartNumberMarker"]

    def complete_audio(self, key: str, upload_id: str, parts: list[dict[str, Any]]) -> str:
        response = self.client.complete_multipart_upload(
            Bucket=self.bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={"Parts": [{"PartNumber": p["part_number"], "ETag": p["etag"]}
                                       for p in parts]},
        )
        version = response.get("VersionId")
        if not version:
            raise RuntimeError("Versioned bucket did not return audio VersionId")
        return version

    def head(self, key: str, version_id: str | None = None) -> dict[str, Any]:
        params = {"Bucket": self.bucket, "Key": key, "ChecksumMode": "ENABLED"}
        if version_id:
            params["VersionId"] = version_id
        return self.client.head_object(**params)

    def get_json(self, key: str, version_id: str) -> dict[str, Any]:
        response = self.client.get_object(Bucket=self.bucket, Key=key, VersionId=version_id)
        return json.loads(response["Body"].read().decode("utf-8"))

    def download_url(self, key: str, version_id: str, expires_in: int) -> str:
        return self.client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self.bucket, "Key": key, "VersionId": version_id},
            ExpiresIn=min(URL_TTL_SECONDS, expires_in),
        )

    def list_object_versions(self, prefix: str) -> list[dict[str, str]]:
        items: list[dict[str, str]] = []
        key_marker = None
        version_marker = None
        while True:
            params: dict[str, Any] = {"Bucket": self.bucket, "Prefix": prefix}
            if key_marker:
                params["KeyMarker"] = key_marker
            if version_marker:
                params["VersionIdMarker"] = version_marker
            response = self.client.list_object_versions(**params)
            for item in response.get("Versions", []) + response.get("DeleteMarkers", []):
                items.append({"Key": item["Key"], "VersionId": item["VersionId"]})
            if not response.get("IsTruncated"):
                return items
            key_marker = response.get("NextKeyMarker")
            version_marker = response.get("NextVersionIdMarker")

    def delete_versions(self, items: list[dict[str, str]]) -> None:
        for offset in range(0, len(items), 1000):
            self.client.delete_objects(
                Bucket=self.bucket,
                Delete={"Objects": items[offset:offset + 1000], "Quiet": True},
            )

    def abort_upload(self, key: str, upload_id: str) -> None:
        self.client.abort_multipart_upload(Bucket=self.bucket, Key=key, UploadId=upload_id)


class Workflow:
    def __init__(self, stepfunctions: Any, ecs: Any, state_machine_arn: str, cluster_arn: str):
        self.stepfunctions = stepfunctions
        self.ecs = ecs
        self.state_machine_arn = state_machine_arn
        self.cluster_arn = cluster_arn

    def start(self, name: str, canonical_input: str) -> str:
        try:
            response = self.stepfunctions.start_execution(
                stateMachineArn=self.state_machine_arn,
                name=name,
                input=canonical_input,
            )
            return response["executionArn"]
        except self.stepfunctions.exceptions.ExecutionAlreadyExists:
            # Version/alias suffix is not present in an execution ARN.
            parts = self.state_machine_arn.split(":")
            return ":".join(parts[:5] + ["execution", parts[6], name])

    def stop_execution(self, arn: str) -> None:
        self.stepfunctions.stop_execution(executionArn=arn, error="Cancelled", cause="Requested by job capability")

    def stop_task(self, arn: str) -> None:
        self.ecs.stop_task(cluster=self.cluster_arn, task=arn, reason="Alignment cancellation requested")

    def describe_execution(self, arn: str) -> dict[str, Any]:
        return self.stepfunctions.describe_execution(executionArn=arn)

    def task_stopped(self, arn: str) -> bool:
        response = self.ecs.describe_tasks(cluster=self.cluster_arn, tasks=[arn])
        tasks = response.get("tasks", [])
        return bool(tasks and tasks[0].get("lastStatus") == "STOPPED")

    def list_tagged_tasks(self, backend_tag: str, job_id: str, limit: int = 100) -> list[str]:
        arns: list[str] = []
        token = None
        while True:
            params: dict[str, Any] = {"cluster": self.cluster_arn, "desiredStatus": "RUNNING",
                                      "maxResults": min(limit, 100)}
            if token:
                params["nextToken"] = token
            response = self.ecs.list_tasks(**params)
            for arn in response.get("taskArns", []):
                tags = self.tags(arn)
                if tags.get("Backend") == backend_tag and tags.get("JobId") == job_id:
                    arns.append(arn)
                    if len(arns) >= limit:
                        return arns
            token = response.get("nextToken")
            if not token:
                return arns

    def tags(self, task_arn: str) -> dict[str, str]:
        response = self.ecs.list_tags_for_resource(resourceArn=task_arn)
        return {item["key"]: item["value"] for item in response.get("tags", [])}
