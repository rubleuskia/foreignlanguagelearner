import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from worker.worker import Worker, WorkerFailure, probe_duration, sha256_file


class Repository:
    def __init__(self, claim):
        self.claim = claim

    def claim_worker(self, job_id, task_arn, now):
        return self.claim


class WorkerAdapterTests(unittest.TestCase):
    def test_hash_streams_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "value"
            path.write_bytes(b"alignment")
            self.assertEqual(sha256_file(path),
                             "47ccb97a79f5a2bff2713968c83bbbea9cd53d2edf6b0a47439910e111c95fe9")

    @patch("worker.worker.subprocess.run")
    def test_probe_rejects_video_and_duration_over_sixty_minutes(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps({
            "streams": [{"codec_type": "audio", "codec_name": "mp3"},
                        {"codec_type": "video", "codec_name": "mjpeg", "disposition": {}}],
            "format": {"duration": "60"},
        }), "")
        with self.assertRaises(WorkerFailure) as video:
            probe_duration(Path("audio"))
        self.assertEqual(video.exception.code, "INVALID_AUDIO")
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps({
            "streams": [{"codec_type": "audio", "codec_name": "aac"}],
            "format": {"duration": "3600.001"},
        }), "")
        with self.assertRaises(WorkerFailure) as duration:
            probe_duration(Path("audio"))
        self.assertEqual(duration.exception.code, "DURATION_LIMIT")

        run.return_value = subprocess.CompletedProcess([], 0, json.dumps({
            "streams": [{"codec_type": "audio", "codec_name": "mp3"},
                        {"codec_type": "video", "codec_name": "mjpeg",
                         "disposition": {"attached_pic": 1}}],
            "format": {"duration": "60"},
        }), "")
        self.assertEqual(probe_duration(Path("audio")), 60)

    def test_duplicate_task_exits_before_download_or_inference(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
                os.environ, {"ECS_TASK_ARN": "arn:task:duplicate"}):
            result = Worker(object(), Repository(False), "bucket", "sha256:image", Path(directory)).run({
                "schema_version": 1, "job_id": "job", "profile_id": "base-guided-v1",
            })
        self.assertEqual(result, {"job_id": "job", "worker_exit_code": 75, "duplicate_claim": True})


if __name__ == "__main__":
    unittest.main()
