import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import epub_text


class EPUBTextTests(unittest.TestCase):
    def make_epub(self, root, documents, spine, properties=None):
        path = root / "book.epub"
        properties = properties or {}
        manifest = "".join(f'<item id="{name}" href="{name}.xhtml" media-type="application/xhtml+xml" properties="{properties.get(name, "")}"/>' for name in documents)
        order = "".join(f'<itemref idref="{name}"/>' for name in spine)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("mimetype", "application/epub+zip")
            archive.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="EPUB/package.opf"/></rootfiles></container>')
            archive.writestr("EPUB/package.opf", f'<package><metadata><title>Book</title><language>pl</language><creator>Author</creator></metadata><manifest>{manifest}</manifest><spine>{order}</spine></package>')
            for name, body in documents.items():
                archive.writestr(f"EPUB/{name}.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>{body}</body></html>')
        return path

    def testSpineOrderInlineTextNotesAndUnicode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self.make_epub(root, {
                "second": '<h2>Drugi</h2><p>Zażółć gęślą.</p>',
                "first": '<h2>Pierwszy</h2><p>To <em>ważne</em><a epub:type="noteref">1</a>, nie roz<em>dzielaj</em>.</p><aside epub:type="footnote">Not narrated</aside>',
                "nav": '<nav>Duplicate contents</nav>'}, ["nav", "first", "second"], {"nav": "nav"})
            result = epub_text.extract(path)
            self.assertEqual([s['href'] for s in result['sections']], ['EPUB/first.xhtml', 'EPUB/second.xhtml'])
            self.assertEqual(result['sections'][0]['text'], 'Pierwszy\n\nTo ważne, nie rozdzielaj.')
            self.assertEqual(result['sections'][1]['text'], 'Drugi\n\nZażółć gęślą.')
            self.assertEqual(result['creators'], ['Author'])
            epub_text.write_extraction(result, root / 'output')
            index = json.loads((root / 'output/epub-index.json').read_text())
            self.assertEqual(index['sections'][0]['file'], 'sections/001.txt')
            with self.assertRaises(FileExistsError):
                epub_text.write_extraction(result, root / 'output')

    def testWolneLekturyProfileRemovesFundraisingAndAnnotations(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.make_epub(Path(temporary), {
                'part1': '<div id="book-text"><h2>I. Tytuł</h2><p>W domu<a class="anchor" href="annotations.xhtml#annotation-1"><sup>1</sup></a>, sam.</p></div>',
                'fund0': '<div id="book-text"><div class="fundraising"><p>Support us</p></div></div>',
                'annotations': '<div id="book-text"><p>Unspoken notes</p></div>',
                'support': '<div id="book-text"><p>Donate</p></div>',
                'last': '<div id="book-text"><p>Licensing</p></div>'
            }, ['part1', 'fund0', 'annotations', 'support', 'last'])
            result = epub_text.extract(path, 'wolne-lektury')
            self.assertEqual(len(result['sections']), 1)
            self.assertEqual(result['sections'][0]['text'], 'I. Tytuł\n\nW domu, sam.')
            self.assertEqual(len(result['skipped']), 4)

    def testUnsafeArchiveReferencesAreRejected(self):
        for href in ['../../outside.xhtml', '/absolute.xhtml', 'https://example.com/text', '%2e%2e/%2e%2e/outside.xhtml']:
            with self.subTest(href=href), self.assertRaises(ValueError):
                epub_text.archive_path('EPUB/package.opf', href)
        self.assertEqual(epub_text.archive_path('EPUB/package.opf', '../Text/part.xhtml#p1'), 'Text/part.xhtml')

    def testCustomEntitiesAreRejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'entities.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('bad.xml', '<!DOCTYPE a [<!ENTITY bad "text">]><a>&bad;</a>')
            with zipfile.ZipFile(path) as archive, self.assertRaises(ValueError):
                epub_text.read_xml(archive, 'bad.xml')


if __name__ == '__main__':
    unittest.main()
