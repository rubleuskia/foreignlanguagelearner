import base64
import hashlib
import unittest

from backend.alignment.domain import (
    PART_SIZE, capability_matches, expected_part_size, part_count, token_hash,
    validate_create, validate_cues, validate_manifest,
)
from backend.alignment.errors import AlignmentError, Unauthorized


def bearer(byte: int = 7) -> str:
    return "Bearer " + base64.urlsafe_b64encode(bytes([byte]) * 32).decode().rstrip("=")


class DomainTests(unittest.TestCase):
    def test_capability_requires_canonical_32_byte_base64url(self):
        digest = token_hash(bearer())
        self.assertEqual(digest, hashlib.sha256(bytes([7]) * 32).hexdigest())
        self.assertTrue(capability_matches(digest, digest))
        for malformed in (None, "Basic value", "Bearer ", "Bearer YQ", bearer() + "="):
            with self.subTest(malformed=malformed), self.assertRaises(Unauthorized):
                token_hash(malformed)

    def test_create_rejects_unknown_fields_and_independent_size_limits(self):
        valid = {
            "language": "pl", "profile_id": "base-guided-v1", "allow_untimed_words": False,
            "audio": {"extension": "mp3", "size_bytes": 1_000_000_000, "sha256": "a" * 64},
            "text": {"size_bytes": 10_000_000, "sha256": "b" * 64},
        }
        self.assertIs(validate_create(valid), valid)
        with self.assertRaises(AlignmentError):
            validate_create({**valid, "owner_id": "attacker"})
        with self.assertRaises(AlignmentError):
            validate_create({**valid, "audio": {**valid["audio"], "size_bytes": 1_000_000_001}})

    def test_multipart_part_sizes(self):
        total = PART_SIZE * 2 + 123
        self.assertEqual(part_count(total), 3)
        self.assertEqual(expected_part_size(total, 1), PART_SIZE)
        self.assertEqual(expected_part_size(total, 3), 123)
        with self.assertRaises(AlignmentError):
            expected_part_size(total, 4)

    def test_cloud_timing_boundary_uses_milliseconds_and_duration_tolerance(self):
        validate_cues([{"start": 0, "end": 1000}, {"start": 1000, "end": 3600100}], 3600)
        with self.assertRaises(AlignmentError) as captured:
            validate_cues([{"start": 0, "end": 3600101}], 3600)
        self.assertEqual(captured.exception.code, "TIMING_OUT_OF_RANGE")
        with self.assertRaises(AlignmentError):
            validate_cues([{"start": 1000, "end": 2000}, {"start": 1999, "end": 3000}], 4)

    def test_manifest_must_pin_inputs_and_complete_artifacts(self):
        job = {"job_id": "job", "profile_id": "base-guided-v1", "audio_version_id": "a1",
               "text_version_id": "t1", "expected_audio_sha256": "a" * 64,
               "expected_text_sha256": "b" * 64}
        artifact = lambda name: {"key": f"jobs/job/attempt/1/{name}", "version_id": name,
                                 "size_bytes": 10, "sha256": "c" * 64}
        manifest = {
            "schema_version": 1, "job_id": "job", "attempt": 1,
            "profile_id": "base-guided-v1", "image_digest": "sha256:image",
            "inputs": {"audio": {"version_id": "a1", "sha256": "a" * 64},
                       "text": {"version_id": "t1", "sha256": "b" * 64}},
            "artifacts": {"srt": artifact("subtitles.srt"), "vtt": artifact("subtitles.vtt"),
                          "json": artifact("alignment.json")},
            "requires_review": True, "counts": {"cues": 2, "words": 4},
        }
        result = validate_manifest(manifest, job=job, manifest_key="manifest", manifest_version_id="m1")
        self.assertTrue(result.requires_review)
        altered = {**manifest, "inputs": {**manifest["inputs"],
                                           "audio": {"version_id": "latest", "sha256": "a" * 64}}}
        with self.assertRaises(AlignmentError):
            validate_manifest(altered, job=job, manifest_key="manifest", manifest_version_id="m1")


if __name__ == "__main__":
    unittest.main()
