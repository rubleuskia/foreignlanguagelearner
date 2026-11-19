import json
from pathlib import Path
import tempfile
import unittest

from pypdf import PdfWriter
import batch_digitize as batch


class BatchEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.sources = Path(self.temp.name) / 'sources'
        self.target = Path(self.temp.name) / 'batch'
        self.sources.mkdir()
        entries = []
        for session, directory in [('4-5 lutego', '4-5_lutego'), ('20-21 kwietnia', '20-21_kwietnia')]:
            folder = self.sources / 'originals/2024' / directory / 'B1'
            folder.mkdir(parents=True)
            for role, kind in [('paper', 'exam_paper'), ('keys', 'transcript_and_answer_keys'), ('audio', 'audio')]:
                path = folder / (role + ('.mp3' if role == 'audio' else '.pdf'))
                if role == 'audio': path.write_bytes(b'isolated audio identity fixture')
                else:
                    writer = PdfWriter(); writer.add_blank_page(width=612, height=792)
                    writer.write(path)
                entries.append({'year': 2024, 'session': session, 'level': 'B1', 'kind': kind,
                    'path': path.relative_to(self.sources).as_posix(), 'url': 'https://example.test/' + path.name,
                    'sha256': batch.digest(path), 'bytes': path.stat().st_size})
        batch.write(self.sources / 'manifest.json', {'entries': entries})

    def test_index_preserves_source_labels_and_prioritizes_latest_b1(self):
        index = batch.initialize(self.sources, self.target)
        self.assertEqual(len(index['jobs']), 2)
        self.assertEqual(index['jobs'][0]['selection']['session'], '20-21 kwietnia')
        self.assertEqual(index['jobs'][0]['directory'], '2024/20-21_kwietnia/B1')
        self.assertEqual(batch.initialize(self.sources, self.target), index)
        with (self.sources / 'manifest.json').open('a') as stream: stream.write(' ')
        with self.assertRaisesRegex(ValueError, 'source identity differs'):
            batch.initialize(self.sources, self.target)

    def test_evidence_is_source_bound_review_pending_and_resumable(self):
        index = batch.initialize(self.sources, self.target)
        job = index['jobs'][0]
        first = batch.extract_one(self.sources, self.target, job, render=False)
        self.assertEqual(first['state'], 'evidence_ready')
        self.assertFalse(first['reviewed_import'])
        root = self.target / job['directory']
        manifest = batch.verify_evidence(root, job)
        self.assertEqual(manifest['page_count'], 2)
        draft = batch.read(root / 'evidence/structure-draft.json')
        self.assertEqual(draft['status'], 'requires_structure_review')
        self.assertEqual(draft['source_refs'], batch.binding(job))
        second = batch.extract_one(self.sources, self.target, job, render=False)
        self.assertTrue(second['cached'])

    def test_corrupt_completed_evidence_is_not_overwritten_as_a_fresh_success(self):
        job = batch.initialize(self.sources, self.target)['jobs'][0]
        batch.extract_one(self.sources, self.target, job, render=False)
        file = self.target / job['directory'] / 'evidence/extracted.json'
        file.write_text('{"tampered":true}')
        result = batch.extract_one(self.sources, self.target, job, render=False)
        self.assertEqual(result['state'], 'failed')
        self.assertIn('integrity', result['error'])
        self.assertEqual(json.loads(file.read_text()), {'tampered': True})

    def test_changed_original_fails_before_extraction_and_keeps_its_hash_binding(self):
        job = batch.initialize(self.sources, self.target)['jobs'][0]
        source = self.sources / job['sources']['paper']['path']
        source.write_bytes(source.read_bytes() + b'changed')
        result = batch.extract_one(self.sources, self.target, job, render=False)
        self.assertEqual(result['state'], 'failed')
        self.assertFalse((self.target / job['directory'] / 'evidence').exists())
        self.assertEqual(result['source_refs'], batch.binding(job))

    def test_archive_path_escape_is_rejected(self):
        manifest = batch.read(self.sources / 'manifest.json')
        manifest['entries'][0]['path'] = '../outside.pdf'
        batch.write(self.sources / 'manifest.json', manifest)
        with self.assertRaises(ValueError): batch.initialize(self.sources, self.target)


if __name__ == '__main__': unittest.main()
