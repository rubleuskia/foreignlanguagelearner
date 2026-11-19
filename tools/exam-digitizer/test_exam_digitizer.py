import copy
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest

from exam_digitizer import (InvalidExam, PreviewHandler, build, canonical_digest, copy_review_images, digest,
                            grade_attempt, inside, validate_audio, validate_exam, write_json, compile_assessment)


REF = [{"source_id": "paper", "page": 1}]
KEY = [{"source_id": "keys", "page": 1}]


def item(id_, response_type, maximum, mode, accepted, options=None):
    return {"id": id_, "label": id_, "position": 1, "prompt": "Pytanie", "response_type": response_type,
            "option_ids": options or [], "max_score_units": maximum, "source_refs": REF,
            "grading": {"mode": mode, "accepted_answers": accepted, "source_refs": KEY}}


def fixture():
    items = [item("q1", "text", 100, "exact", ["żółw"]),
             item("q2", "multi_choice", 100, "set", [["a", "b"]], ["a", "b", "c"]),
             item("q3", "text", 100, "ai_stub", [])]
    items[2]['grading'].update(reference_answer='Przykładowa odpowiedź',
                               rubric={'text':'1 punkt za poprawną odpowiedź zgodną z poleceniem.',
                                       'source_refs':KEY})
    for position, row in enumerate(items, 1):
        row["position"] = position
    task = {"id": "listening-I", "label": "I", "position": 1, "instruction": "Instrukcja",
            "interaction_type": "mixed", "max_score_units": 300, "source_refs": REF,
            "blocks": [], "options": [{"id": o, "label": o, "text": o, "source_refs": REF} for o in "abc"], "items": items}
    task['ai_assessment']=compile_assessment(task,'test-exam')
    sources = [{"id": id_, "url": f"https://example.org/{id_}", "path": f"sources/{id_}.bin",
                "sha256": "0" * 64, "bytes": 1, "media_type": "audio/mpeg" if id_ == "audio" else "application/pdf",
                **({"page_count": 1} if id_ != "audio" else {})} for id_ in ("paper", "keys", "audio")]
    return {"schema_version": "1.1", "id": "test-exam", "revision": "0" * 64, "title": "Egzamin", "language": "pl",
            "level": "B1", "audience": "adults", "session": {"label": "test", "start_date": "2024-06-22", "end_date": "2024-06-23"},
            "sources": sources, "interactive_section_ids": ["listening"], "provenance": {"profile_sha256": "0" * 64, "archive_url": "https://example.org/archive", "generator": "test"},
            "sections": [{"id": "listening", "title": "Słuchanie", "position": 1, "max_score_units": 300,
                          "time_limit_seconds": 30, "source_refs": REF, "tasks": [task]}]}


class ImportContractTests(unittest.TestCase):
    def test_absolute_review_image_paths_are_rebased_to_portable_package_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            review, stage = root / 'review', root / 'package'
            source = review / 'keys/page-001.png'
            source.parent.mkdir(parents=True)
            source.write_bytes(b'keys-image')
            report = {'rendered_evidence_directory': str(review), 'rendered_pages': [
                {'path': str(source), 'sha256': digest(source), 'source_refs': KEY}]}
            copy_review_images(report, stage)
            row = report['rendered_pages'][0]
            self.assertEqual(row['path'], 'evidence/content-review/keys/page-001.png')
            self.assertEqual((stage / row['path']).read_bytes(), source.read_bytes())

    def test_review_images_from_different_pdfs_cannot_overwrite_each_other(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            review, stage = root / 'review', root / 'package'
            rows = []
            for role in ('paper', 'keys'):
                file = review / role / 'page-001.png'
                file.parent.mkdir(parents=True)
                file.write_bytes(role.encode())
                rows.append({'path': f'{role}/page-001.png', 'sha256': digest(file),
                             'source_refs': [{'source_id': role, 'page': 1}]})
            report = {'rendered_evidence_directory': str(review), 'rendered_pages': rows}
            copy_review_images(report, stage)
            self.assertNotEqual(rows[0]['path'], rows[1]['path'])
            for role, row in zip(('paper', 'keys'), rows):
                self.assertEqual((stage / row['path']).read_bytes(), role.encode())
                self.assertEqual(digest(stage / row['path']), row['sha256'])

    def test_invalid_total_or_missing_origin_page_is_rejected(self):
        for change in ("total", "page", "gap", "option"):
            exam = fixture()
            task = exam["sections"][0]["tasks"][0]
            if change == "total":
                task["items"][0]["max_score_units"] = 25
            elif change == "page":
                task["source_refs"] = [{"source_id": "paper", "page": 2}]
            elif change == "gap":
                task["blocks"] = [{"id": "block", "type": "paragraph", "text": "{{nonexistent}}", "source_refs": REF}]
            else:
                task["items"][1]["grading"]["accepted_answers"] = [["missing"]]
            with self.subTest(change=change), self.assertRaises(InvalidExam):
                validate_exam(exam)

    def test_duplicate_identity_cannot_silently_overwrite_an_answer(self):
        exam = fixture()
        exam["sections"][0]["tasks"][0]["items"][1]["id"] = "q1"
        with self.assertRaisesRegex(InvalidExam, "Duplicate content ID"):
            validate_exam(exam)

    def test_ai_pending_is_neither_zero_nor_a_fabricated_total(self):
        exam = fixture()
        validate_exam(exam)
        result = grade_attempt(exam, {"revision": exam["revision"], "responses": {"q1": "żółw", "q2": ["b", "a"], "q3": "dowolna odpowiedź"}})
        section = result["sections"][0]
        self.assertIsNone(section["score_units"])
        self.assertEqual(section["objective_score_units"], 200)
        self.assertEqual(section["items"][2]["status"], "pending_ai")
        self.assertIsNone(section["items"][2]["awarded_score_units"])

    def test_diacritics_revision_and_unknown_options_are_not_ignored(self):
        exam = fixture()
        request = {"revision": exam["revision"], "responses": {"q1": "zolw", "q2": ["a", "b"]}}
        self.assertEqual(grade_attempt(exam, request)["sections"][0]["objective_score_units"], 100)
        request["revision"] = "1" * 64
        with self.assertRaises(InvalidExam):
            grade_attempt(exam, request)
        request["revision"] = exam["revision"]
        request["responses"]["q2"] = ["a", "b", "not-an-option"]
        with self.assertRaises(InvalidExam):
            grade_attempt(exam, request)

    def test_manual_numeric_answers_receive_partial_credit_without_ai_or_duplicate_credit(self):
        exam = fixture()
        row = exam["sections"][0]["tasks"][0]["items"][1]
        row.update(response_type="text", option_ids=[])
        row["grading"].update(mode="token_membership", accepted_answers=["2", "4"], max_tokens=2)
        validate_exam(exam)
        for answer, expected in (("2", 50), ("2, 4", 100), ("4 / 2", 100), ("2---4", 100), ("2 2", 50), ("2,5", 50), ("24", 0), ("", 0)):
            with self.subTest(answer=answer):
                result = grade_attempt(exam, {"revision": exam["revision"], "responses": {"q2": answer}})
                item_result = next(i for i in result["sections"][0]["items"] if i["item_id"] == "q2")
                self.assertEqual(item_result["awarded_score_units"], expected)
        with self.assertRaisesRegex(InvalidExam, "Too many token answers"):
            grade_attempt(exam, {"revision": exam["revision"], "responses": {"q2": "1,2,3,4,5"}})

    def test_writing_alternative_sets_do_not_triple_the_section_maximum(self):
        exam = fixture()
        sets = []
        for position, label in enumerate(("I", "II", "III"), 1):
            items = [item(f"writing-{label}-{part}", "long_text", None, "ai_stub", []) for part in ("a", "b")]
            items[1]["position"] = 2
            sets.append({"id": f"writing-{label}", "label": label, "position": position, "instruction": "Wybierz zestaw",
                         "interaction_type": "writing_set", "max_score_units": 3000, "source_refs": REF,
                         "blocks": [], "options": [], "items": items})
        exam["sections"].append({"id": "writing", "title": "Pisanie", "position": 2, "max_score_units": 3000,
                                 "source_refs": REF, "selection": {"mode": "choose_one", "task_ids": [t["id"] for t in sets]}, "tasks": sets})
        validate_exam(exam)
        preserved = grade_attempt(exam, {"revision": exam["revision"], "responses": {}})
        self.assertEqual([s["section_id"] for s in preserved["sections"]], ["listening"])
        exam["interactive_section_ids"].append("writing")
        request = {"revision": exam["revision"], "responses": {}, "selected_tasks": {"writing": ["writing-II"]}}
        result = grade_attempt(exam, request)["sections"][1]
        self.assertEqual(result["max_score_units"], 3000)
        self.assertEqual(len(result["items"]), 2)
        self.assertTrue(all(row["item_id"].startswith("writing-II-") for row in result["items"]))

    def test_audio_must_match_original_and_have_all_nonoverlapping_occurrences(self):
        exam = fixture()
        audio = {"source": {"sha256": "0" * 64, "duration_ms": 10000}, "tasks": [
            {"task_label": "I", "occurrences": [{"start_ms": 100, "end_ms": 1000}, {"start_ms": 1200, "end_ms": 2200}]}]}
        self.assertEqual(validate_audio(audio, exam)["occurrence_count"], 2)
        audio["source"]["sha256"] = "1" * 64
        with self.assertRaises(InvalidExam):
            validate_audio(audio, exam)
        audio["source"]["sha256"] = "0" * 64
        audio["tasks"][0]["occurrences"][1]["start_ms"] = 900
        with self.assertRaises(InvalidExam):
            validate_audio(audio, exam)

    def test_path_traversal_and_symlink_escape_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(InvalidExam):
                inside(root, "../outside")
            (root / "link").symlink_to(root.parent)
            with self.assertRaises(InvalidExam):
                inside(root, "link/outside")

    def test_build_is_reproducible_and_source_corruption_cannot_be_imported(self):
        from pypdf import PdfWriter
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "sources"
            sources.mkdir()
            entries = []
            for name, kind in (("paper.pdf", "exam_paper"), ("keys.pdf", "transcript_and_answer_keys"), ("audio.mp3", "audio")):
                path = sources / name
                if name.endswith("pdf"):
                    writer = PdfWriter()
                    writer.add_blank_page(width=200, height=200)
                    writer.write(path)
                else:
                    path.write_bytes(b"test-only-audio")
                entries.append({"year": 2024, "session": "test", "level": "B1", "kind": kind, "url": f"https://example.org/{name}",
                                "path": name, "sha256": digest(path), "bytes": path.stat().st_size})
            write_json(sources / "manifest.json", {"entries": entries})
            profile = fixture()
            for key in ("schema_version", "revision", "sources", "provenance"):
                profile.pop(key)
            profile["source_selection"] = {"year": 2024, "session": "test", "level": "B1"}
            profile_path = root / "profile.json"
            write_json(profile_path, profile)
            build(profile_path, sources, root / "one", render=False)
            build(profile_path, sources, root / "two", render=False)
            one = json.loads((root / "one" / "exam.json").read_text())
            two = json.loads((root / "two" / "exam.json").read_text())
            self.assertEqual(one["revision"], two["revision"])
            stale = copy.deepcopy(one)
            stale["sections"][0]["tasks"][0]["items"][0]["grading"]["accepted_answers"] = ["inny klucz"]
            with self.assertRaisesRegex(InvalidExam, "Content revision differs"):
                validate_exam(stale, root / "one")
            with self.assertRaises(InvalidExam):
                build(profile_path, sources, root / "one", render=False)
            (sources / "audio.mp3").write_bytes(b"modified")
            with self.assertRaisesRegex(InvalidExam, "differs from download manifest"):
                build(profile_path, sources, root / "corrupted", render=False)
            self.assertFalse((root / "corrupted").exists())


class LocalPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "sources").mkdir()
        (self.root / "sources" / "audio.mp3").write_bytes(bytes(range(100)))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), PreviewHandler)
        self.server.bundle = self.root
        self.server.exam = fixture()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, method, path, headers=None, body=None):
        connection = HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request(method, path, headers=headers or {}, body=body)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_browser_seeking_gets_exact_bytes_and_bad_ranges_are_rejected(self):
        status, headers, body = self.request("GET", "/sources/audio.mp3", {"Range": "bytes=10-19"})
        self.assertEqual(status, 206)
        self.assertEqual(headers["Content-Range"], "bytes 10-19/100")
        self.assertEqual(body, bytes(range(10, 20)))
        status, _, body = self.request("GET", "/sources/audio.mp3", {"Range": "bytes=-3"})
        self.assertEqual(status, 206)
        self.assertEqual(body, bytes(range(97, 100)))
        self.assertEqual(self.request("GET", "/sources/audio.mp3", {"Range": "bytes=900-"})[0], 416)
        self.assertEqual(self.request("GET", "/sources/../../outside")[0], 404)

    def test_ai_stub_endpoint_returns_pending_and_rejects_foreign_origin(self):
        payload = json.dumps({"revision": "0" * 64, "responses": {"q1": "żółw", "q2": ["a", "b"]}}).encode()
        status, _, body = self.request("POST", "/api/grade", {"Content-Type": "application/json"}, payload)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["ai_integration"], "stub_no_inference")
        self.assertIsNone(json.loads(body)["sections"][0]["score_units"])
        self.assertEqual(self.request("POST", "/api/grade", {"Content-Type": "application/json", "Origin": "https://other.example"}, payload)[0], 403)


if __name__ == "__main__":
    unittest.main()
