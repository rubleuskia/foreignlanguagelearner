import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import align
from guided import plan_chunks


def word(text, start, end):
    return {"word": text, "start": start, "end": end}


class SubtitleTests(unittest.TestCase):
    def test_engine_duplicate_repair_preserves_intentional_repetition(self):
        words = [word(" Tak", 0, 1), word(" Tak", 1, 2), word(" jest.", 2, 3)]
        data = {"segments": [{"words": words}]}
        fixed = align.remove_engine_duplicates(data, "Tak jest.")
        self.assertEqual(len(fixed["engine_duplicate_words"]), 1)
        self.assertEqual(len(data["segments"][0]["words"]), 3)
        self.assertNotIn("engine_duplicate_words", align.remove_engine_duplicates(data, "Tak Tak jest."))
        self.assertIs(align.remove_engine_duplicates(data, "Nie jest."), data)

    def test_guided_anchors_and_insufficient_matches(self):
        book = "one two three four five six seven eight nine ten"
        words = [word(" " + w, i * 20, i * 20 + 1) for i, w in enumerate(book.split())]
        with self.assertRaises(ValueError):
            plan_chunks("unrelated content", {"segments": [{"words": words}]}, 300)
        self.assertEqual(plan_chunks(book, {"segments": [{"words": words}]}, 200),
                         [(0, 0.0), (3, 60.0), (6, 120.0), (10, 200)])

    def test_untimed_words_retained_only_with_opt_in(self):
        words = [word("—", 0, 0), word(" Tak.", 0, 1), word(" Koniec.", 1, 1)]
        data = {"segments": [{"words": words}]}
        with self.assertRaises(ValueError):
            align.validate_words(data, "— Tak. Koniec.")
        align.validate_words(data, "— Tak. Koniec.", allow_untimed=True)
        cues = align.make_cues(words)
        self.assertEqual(" ".join(c["text"] for c in cues), "— Tak. Koniec.")
        self.assertTrue(all(c["end"] > c["start"] for c in cues))
    def test_unicode_and_newlines(self):
        self.assertEqual(align.clean_text("\ufeffZażółć\r\n ge\u0328ślą\tjaźń."),
                         "Zażółć gęślą jaźń.")

    def test_missing_text_and_bad_timings_fail(self):
        for words, text in [([word("Tak", 0, 1)], "Nie"),
                            ([word("Tak", 1, 1)], "Tak"),
                            ([word("Tak", 0, float("nan"))], "Tak"),
                            ([word("Tak", 0, 2), word(" jest", 1, 3)], "Tak jest")]:
            with self.subTest(words=words), self.assertRaises(ValueError):
                align.validate_words({"segments": [{"words": words}]}, text)

    def test_grouping_pause_sentence_and_offset(self):
        words = [word("Zażółć", 0, .5), word(" gęślą.", .5, 1),
                 word(" Dalej", 2, 2.5), word(" teraz", 4, 5)]
        cues = align.make_cues(words, offset=60)
        self.assertEqual([c["text"] for c in cues], ["Zażółć gęślą.", "Dalej", "teraz"])
        self.assertEqual(cues[0]["start"], 60000)
        self.assertEqual(cues[-1]["end"], 65000)

    def test_width_duration_and_no_dropped_words(self):
        words = [word(" one" if i else "one", i, i + .5) for i in range(8)]
        cues = align.make_cues(words, max_chars=7, max_duration=2)
        self.assertEqual(" ".join(c["text"].replace("\n", " ") for c in cues),
                         " ".join(["one"] * 8))
        for cue in cues:
            self.assertLessEqual(len(cue["text"].splitlines()), 2)
            self.assertLessEqual(cue["end"] - cue["start"], 2000)

    def test_render_escaping_and_hour_rollover(self):
        cues = [{"start": 3599999, "end": 3600001, "text": "Łódź <tak> & nie"}]
        self.assertIn("00:59:59,999 --> 01:00:00,001", align.render(cues, "srt"))
        self.assertIn("Łódź &lt;tak&gt; &amp; nie", align.render(cues, "srt"))
        self.assertTrue(align.render(cues, "vtt").startswith("WEBVTT\n\n1\n"))

    def test_cli_with_fake_backend_and_overwrite_protection(self):
        data = {"segments": [{"words": [word("Cześć", 0, 1), word(" świecie.", 1, 2)]}]}
        result = SimpleNamespace(to_dict=lambda: data)
        model = SimpleNamespace(align=lambda *a, **kw: result)
        backend = SimpleNamespace(load_model=lambda *a, **kw: model)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "book.txt").write_text("Cześć świecie.", encoding="utf-8")
            (root / "audio.wav").write_bytes(b"fake audio; backend is mocked")
            argv = ["--text", str(root / "book.txt"), "--audio", str(root / "audio.wav"),
                    "--output", str(root / "out")]
            with patch.dict("sys.modules", {"stable_whisper": backend}), \
                 patch("align.shutil.which", return_value="ffmpeg"), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(align.main(argv), 0)
                before = (root / "out/subtitles.srt").read_bytes()
                self.assertEqual(align.main(argv), 1)
                self.assertEqual((root / "out/subtitles.srt").read_bytes(), before)
                data["segments"][0]["words"][0]["end"] = 0
                failed_argv = argv[:-1] + [str(root / "failed")]
                self.assertEqual(align.main(failed_argv), 1)
                self.assertTrue((root / "failed/alignment-failed.json").is_file())
                self.assertFalse((root / "failed/subtitles.srt").exists())
            report = json.loads((root / "out/alignment.json").read_text())
            self.assertEqual(report["schema_version"], 1)


if __name__ == "__main__":
    unittest.main()
