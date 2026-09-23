import base64
import copy
import unittest

from backend.alignment.finalizer import finalize_event
from backend.alignment.repository import MemoryRepository


class Storage:
    def __init__(self, manifest, checksum_ok=True):
        self.manifest = manifest
        self.checksum_ok = checksum_ok

    def get_json(self, key, version):
        return copy.deepcopy(self.manifest)

    def head(self, key, version):
        artifact = next(value for value in self.manifest["artifacts"].values() if value["key"] == key)
        checksum = base64.b64encode(bytes.fromhex(artifact["sha256"])).decode()
        return {"VersionId": version, "ContentLength": artifact["size_bytes"],
                "ChecksumSHA256": checksum if self.checksum_ok else "wrong"}


def running_job():
    return {
        "job_id": "job", "status": "running", "revision": 3, "profile_id": "base-guided-v1",
        "audio_version_id": "a1", "text_version_id": "t1",
        "expected_audio_sha256": "a" * 64, "expected_text_sha256": "b" * 64,
        "admission_released": False, "cleanup_pending": False,
        "manifest_key": "jobs/job/attempt/1/manifest.json", "manifest_version_id": "m1",
    }


def manifest():
    artifact = lambda name: {"key": f"jobs/job/attempt/1/{name}", "version_id": name,
                             "size_bytes": 10, "sha256": "c" * 64}
    return {
        "schema_version": 1, "job_id": "job", "attempt": 1,
        "profile_id": "base-guided-v1", "image_digest": "sha256:image",
        "inputs": {"audio": {"version_id": "a1", "sha256": "a" * 64},
                   "text": {"version_id": "t1", "sha256": "b" * 64}},
        "artifacts": {"srt": artifact("subtitles.srt"), "vtt": artifact("subtitles.vtt"),
                      "json": artifact("alignment.json")},
        "requires_review": False, "counts": {"cues": 2, "words": 5},
    }


class FinalizerTests(unittest.TestCase):
    def setUp(self):
        self.repository = MemoryRepository()
        self.repository.jobs["job"] = running_job()
        self.repository.active = 1

    def test_publishes_only_when_s3_versions_sizes_and_checksums_match(self):
        result = finalize_event({"job_id": "job", "worker_exit_code": 0},
                                self.repository, Storage(manifest()), 100)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(self.repository.active, 0)
        self.assertEqual(set(self.repository.jobs["job"]["artifacts"]), {"srt", "vtt", "json"})

    def test_exit_zero_with_mismatching_artifact_is_failure(self):
        result = finalize_event({"job_id": "job", "worker_exit_code": 0},
                                self.repository, Storage(manifest(), checksum_ok=False), 100)
        self.assertEqual(result, {"job_id": "job", "status": "failed",
                                  "error_code": "INFRASTRUCTURE_FAILURE"})
        self.assertNotIn("artifacts", self.repository.jobs["job"])

    def test_exit_137_maps_to_resource_limit_without_exposing_task_details(self):
        result = finalize_event(
            {"job_id": "job", "task": {"Containers": [{"ExitCode": 137}]}},
            self.repository,
            Storage(manifest()),
            100,
        )
        self.assertEqual(result, {"job_id": "job", "status": "failed",
                                  "error_code": "WORKER_RESOURCE_LIMIT"})


if __name__ == "__main__":
    unittest.main()
