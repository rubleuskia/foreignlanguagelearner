import base64
import copy
import hashlib
import unittest
import uuid

from backend.alignment.domain import part_count
from backend.alignment.errors import AlignmentError, Conflict, NotFound
from backend.alignment.repository import MemoryRepository
from backend.alignment.service import AlignmentService


def bearer(byte: int) -> str:
    return "Bearer " + base64.urlsafe_b64encode(bytes([byte]) * 32).decode().rstrip("=")


def request(audio_size=100):
    return {
        "language": "pl", "profile_id": "base-guided-v1", "allow_untimed_words": False,
        "audio": {"extension": "mp3", "size_bytes": audio_size, "sha256": "a" * 64},
        "text": {"size_bytes": 20, "sha256": "b" * 64},
    }


class Storage:
    def __init__(self):
        self.aborted = []
        self.audio_size = 100

    def create_audio_upload(self, key, sha256):
        self.audio_size = request()["audio"]["size_bytes"]
        return "upload-1"

    def abort_upload(self, key, upload_id):
        self.aborted.append((key, upload_id))

    def text_put_url(self, key, checksum):
        return {"url": "https://upload.example/text", "headers": {"x-amz-checksum-sha256": checksum}}

    def upload_part_url(self, key, upload_id, part_number, content_length):
        return {"part_number": part_number, "url": f"https://upload.example/{part_number}",
                "headers": {"content-length": str(content_length)}}

    def list_parts(self, key, upload_id):
        return [{"PartNumber": 1, "ETag": '"etag"', "Size": 100}]

    def complete_audio(self, key, upload_id, parts):
        return "audio-version"

    def head(self, key, version_id=None):
        if key.endswith("transcript.txt"):
            return {"ContentLength": 20, "VersionId": "text-version"}
        return {"ContentLength": 100, "VersionId": "audio-version"}

    def download_url(self, key, version, remaining):
        return f"https://download.example/{version}"


class Workflow:
    def __init__(self):
        self.starts = []
        self.stops = []

    def start(self, name, content):
        self.starts.append((name, content))
        return f"arn:execution:{name}"

    def stop_execution(self, arn):
        self.stops.append(("execution", arn))

    def stop_task(self, arn):
        self.stops.append(("task", arn))


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.now = 1_800_000_000
        self.repo = MemoryRepository()
        self.storage = Storage()
        self.workflow = Workflow()
        self.service = AlignmentService(self.repo, self.storage, self.workflow,
                                        bucket="bucket", state_machine_arn="arn:version:1",
                                        accept_new_jobs=True, clock=lambda: self.now)

    def create(self, token=bearer(1), key=None):
        key = key or str(uuid.uuid4())
        return self.service.create(request(), token, key), key

    def complete(self, job_id, token=bearer(1)):
        return self.service.complete_upload(job_id, {"parts": [{"part_number": 1, "etag": "etag"}]}, token)

    def test_create_is_idempotent_and_token_cannot_span_jobs(self):
        (status, first), key = self.create()
        self.assertEqual(status, 201)
        replay_status, replay = self.service.create(request(), bearer(1), key)
        self.assertEqual((replay_status, replay["job_id"]), (200, first["job_id"]))
        changed = request()
        changed["allow_untimed_words"] = True
        with self.assertRaises(Conflict):
            self.service.create(changed, bearer(1), key)
        with self.assertRaises(Conflict) as captured:
            self.service.create(request(), bearer(1), str(uuid.uuid4()))
        self.assertEqual(captured.exception.code, "TOKEN_ALREADY_USED")

    def test_cross_job_capability_is_indistinguishable_from_unknown_job(self):
        (_, created), _ = self.create()
        for job_id, token in ((created["job_id"], bearer(2)), (str(uuid.uuid4()), bearer(1))):
            with self.subTest(job_id=job_id), self.assertRaises(NotFound):
                self.service.status(job_id, token)

    def test_upload_completion_pins_versions_and_start_is_replayed(self):
        (_, created), _ = self.create()
        job_id = created["job_id"]
        complete = self.complete(job_id)
        self.assertTrue(complete["upload_complete"])
        started = self.service.start(job_id, {}, bearer(1))
        self.assertEqual(started["status"], "starting")
        self.assertEqual(len(self.workflow.starts), 1)
        replay = self.service.start(job_id, {}, bearer(1))
        self.assertEqual(replay["status"], "starting")
        self.assertEqual(len(self.workflow.starts), 1)
        stored = self.repo.get_job(job_id)
        self.assertEqual(stored["audio_version_id"], "audio-version")
        self.assertIn('"version_id":"audio-version"', stored["canonical_execution_input"])

    def test_active_slot_released_exactly_once_and_late_success_loses_to_cancel(self):
        (_, created), _ = self.create()
        job_id = created["job_id"]
        self.complete(job_id)
        self.service.start(job_id, {}, bearer(1))
        self.assertEqual(self.repo.active, 1)
        job = self.repo.get_job(job_id)
        self.repo.request_cancel(job, self.now)
        cancelled = self.repo.finalize(self.repo.get_job(job_id), status="cancelled", now=self.now)
        self.assertEqual((cancelled["status"], self.repo.active), ("cancelled", 0))
        late = self.repo.finalize(cancelled, status="succeeded", now=self.now, manifest={"manifest_key": "late"})
        self.assertEqual((late["status"], self.repo.active), ("cancelled", 0))

    def test_kill_switch_blocks_new_cost_and_upload_renewal(self):
        (_, created), _ = self.create()
        self.service.accept_new_jobs = False
        with self.assertRaises(AlignmentError) as create_error:
            self.service.create(request(), bearer(2), str(uuid.uuid4()))
        self.assertEqual(create_error.exception.code, "NEW_JOBS_DISABLED")
        with self.assertRaises(AlignmentError):
            self.service.upload_urls(created["job_id"], {"part_numbers": [1]}, bearer(1))


if __name__ == "__main__":
    unittest.main()
