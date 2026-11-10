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

    @patch.dict(os.environ, {"OPERATOR_ALIGNMENT_PILOT": "pl-300-v1"})
    @patch("worker.worker.subprocess.run")
    def test_pilot_probes_real_duration_before_alignment(self, run):
        for duration in (300, 300.001):
            run.return_value = subprocess.CompletedProcess([], 0, json.dumps({
                "streams": [{"codec_type": "audio", "codec_name": "pcm_s16le"}],
                "format": {"duration": str(duration)},
            }), "")
            if duration == 300:
                self.assertEqual(probe_duration(Path("audio")), 300)
            else:
                with self.assertRaises(WorkerFailure) as error:
                    probe_duration(Path("audio"))
                self.assertEqual(error.exception.code, "DURATION_LIMIT")
        with self.assertRaises(WorkerFailure):
            Worker(object(), Repository(True), "bucket", "sha256:image", Path("/" )).run({
                "schema_version": 1, "profile_id": "base-guided-v1", "job_id": "job", "language": "en"})

    def test_duplicate_task_exits_before_download_or_inference(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
                os.environ, {"ECS_TASK_ARN": "arn:task:duplicate"}):
            result = Worker(object(), Repository(False), "bucket", "sha256:image", Path(directory)).run({
                "schema_version": 1, "job_id": "job", "profile_id": "base-guided-v1",
            })
        self.assertEqual(result, {"job_id": "job", "worker_exit_code": 75, "duplicate_claim": True})


if __name__ == "__main__":
    unittest.main()
