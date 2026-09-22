import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import batch_align


class BatchAlignTests(unittest.TestCase):
    def make_book(self, root, count=3, invalid_coverage=False):
        root.mkdir()
        words = [f"word{i}" for i in range(count)]
        text = " ".join(words)
        (root / "transcript.txt").write_text(text, encoding="utf-8")
        tracks = []
        for index in range(count):
            audio = root / f"{index:03}.mp3"
            audio.write_bytes(f"audio-{index}".encode())
            start = index + (1 if invalid_coverage and index == 1 else 0)
            tracks.append({"id": f"{index:03}", "title": f"Track {index}",
                           "audio": audio.name, "alignmentStatus": "untimed",
                           "textRange": {"startWord": start, "endWord": index + 1}})
        manifest = {"format": batch_align.FORMAT, "schemaVersion": 1, "title": "Synthetic",
                    "sourceLanguage": "pl", "transcript": "transcript.txt",
                    "textMapping": {"normalization": batch_align.NORMALIZATION,
                                    "normalizedSHA256": hashlib.sha256(text.encode()).hexdigest(),
                                    "wordCount": count}, "tracks": tracks}
        path = root / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    def args(self, manifest, output, previous=None, track_id=None):
        return argparse.Namespace(manifest=manifest, output=output, previous_output=previous,
            track_id=track_id, language=None, model="test", token_step=100, guided=False,
            allow_untimed_words=False, device="cpu", model_dir=None, format="srt",
            max_chars=42, max_duration=6.0, max_gap=0.8)

    @staticmethod
    def aligner(model, track, args):
        tokens = track["text"].split()
        words = [{"word": token if index == 0 else " " + token,
                  "start": float(index), "end": float(index + 1)}
                 for index, token in enumerate(tokens)]
        data = {"segments": [{"words": words, "text": track["text"]}]}
        return data, batch_align.align.make_cues(words), [], False

    def test_28_tracks_publish_report_manifest_and_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            manifest = self.make_book(base / "input", count=28)
            output = base / "output"
            result = batch_align.run(self.args(manifest, output), model_loader=lambda _: object(), aligner=self.aligner)
            self.assertEqual(result, 0)
            report = json.loads((output / "batch-report.json").read_text())
            self.assertEqual([track["track_id"] for track in report["tracks"]],
                             [f"{index:03}" for index in range(28)])
            self.assertTrue((output / "book" / "manifest.json").is_file())
            with zipfile.ZipFile(output / "book.book.zip") as archive:
                self.assertIn("manifest.json", archive.namelist())
                self.assertIn("audio/027.mp3", archive.namelist())
                self.assertIn("subtitles/027.srt", archive.namelist())

    def test_invalid_coverage_fails_before_model_load(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            manifest = self.make_book(base / "input", invalid_coverage=True)
            loaded = []
            with self.assertRaisesRegex(ValueError, "contiguous"):
                batch_align.run(self.args(manifest, base / "output"),
                                model_loader=lambda _: loaded.append(True), aligner=self.aligner)
            self.assertEqual(loaded, [])

    def test_track_failure_writes_report_without_importable_book(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            manifest = self.make_book(base / "input")
            def failing(model, track, args):
                if track["manifest"]["id"] == "001":
                    raise ValueError("synthetic mismatch")
                return self.aligner(model, track, args)
            output = base / "output"
            result = batch_align.run(self.args(manifest, output), model_loader=lambda _: object(), aligner=failing)
            self.assertEqual(result, 1)
            self.assertFalse((output / "book").exists())
            report = json.loads((output / "batch-report.json").read_text())
            self.assertEqual(report["failed_track_ids"], ["001"])
            self.assertTrue((output / "tracks" / "000" / "subtitles.srt").is_file())

    def test_rerun_reuses_unchanged_tracks_and_realigns_selected_track(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            manifest = self.make_book(base / "input")
            first = base / "first"
            self.assertEqual(batch_align.run(self.args(manifest, first),
                                             model_loader=lambda _: object(), aligner=self.aligner), 0)
            called = []
            def selected(model, track, args):
                called.append(track["manifest"]["id"])
                return self.aligner(model, track, args)
            second = base / "second"
            args = self.args(manifest, second, previous=first, track_id="001")
            self.assertEqual(batch_align.run(args, model_loader=lambda _: object(), aligner=selected), 0)
            self.assertEqual(called, ["001"])
            self.assertTrue((second / "tracks" / "000" / "alignment.json").is_file())


if __name__ == "__main__":
    unittest.main()
