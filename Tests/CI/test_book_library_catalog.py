import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('prepare_library', ROOT / 'scripts/prepare-book-library.py')
LIBRARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIBRARY)


class BookCatalogTests(unittest.TestCase):
    def test_publication_preserves_stable_id_and_adds_real_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / 'source', Path(temp) / 'output'
            book = source / 'lalka'
            book.mkdir(parents=True)
            archive = book / 'example.book.zip'
            def write(title):
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr('manifest.json', json.dumps(dict(title=title, sourceLanguage='pl', transcript='book.txt', tracks=[dict(id='one')])) )
                    z.writestr('book.txt', 'A\u00a0small\n story')
            write('Original')
            LIBRARY.prepare(source, output)
            first = json.loads((output / 'catalog.json').read_text())['books'][0]
            write('Renamed')
            LIBRARY.prepare(source, output)
            second = json.loads((output / 'catalog.json').read_text())['books'][0]
            self.assertEqual(first['id'], second['id'])
            self.assertNotEqual(first['sha256'], second['sha256'])
            self.assertEqual(first['contentFingerprint'], second['contentFingerprint'])
            self.assertEqual(second['author'], 'Bolesław Prus')
            self.assertEqual(second['chapterCount'], 1)
            # Shared Swift/Python identity vector; title and ZIP packaging are excluded.
            self.assertEqual(second['contentFingerprint'], LIBRARY.hashlib.sha256(b'A small story\0one').hexdigest())
            with zipfile.ZipFile(book / 'duplicate.book.zip', 'w') as z:
                z.writestr('manifest.json', json.dumps(dict(title='Another', sourceLanguage='pl', transcript='book.txt', tracks=[dict(id='one')])))
                z.writestr('book.txt', 'Another')
            with self.assertRaisesRegex(ValueError, 'Duplicate catalog ID'):
                LIBRARY.prepare(source, output)
