import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from book_processing import process, unpack, validate_cues


class BookProcessingTests(unittest.TestCase):
    def archive(self, root, names, audio=None):
        path = root / 'input.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in names.items():
                archive.writestr(name, value)
            if audio:
                archive.write(audio, 'audio.mp3')
        return path

    def test_unsafe_archive_paths_and_duplicates_rejected(self):
        for name in ['../outside.txt', '/absolute', 'a\\b', 'C:drive']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = self.archive(root, {name: b'bad'})
                with self.assertRaisesRegex(ValueError, 'INVALID_ARCHIVE'):
                    unpack(source, root / 'out')

    def test_missing_or_non_audio_manifest_entries_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self.archive(root, {'input.json': json.dumps({'schemaVersion': 1,
                'audio': ['missing.mp3'], 'text': 'text.txt'}), 'text.txt': 'words'})
            with self.assertRaisesRegex(ValueError, 'INVALID_ARCHIVE'):
                unpack(source, root / 'out')

    def test_book_cues_have_no_five_minute_limit(self):
        validate_cues([{'start': 0, 'end': 600_000}], 601)
        with self.assertRaisesRegex(ValueError, 'INVALID_TIMINGS'):
            validate_cues([{'start': 0, 'end': 602_000}], 601)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required')
    def test_complete_package_pipeline_over_five_minutes_with_fake_engine(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audio = root / 'source.mp3'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440',
                '-t', '306', '-ac', '1', '-ar', '16000', '-b:a', '16k', str(audio)], check=True)
            source = self.archive(root, {'input.json': json.dumps({'schemaVersion': 1,
                'audio': ['audio.mp3'], 'text': 'text.txt'}), 'text.txt': 'A long book'}, audio)
            work = root / 'work'; work.mkdir()
            stages = []
            def engine(args):
                args.output.mkdir()
                (args.output / 'subtitles.srt').write_text('1\n00:00:00,000 --> 00:05:05,000\nA long book\n')
                words = [{'word': text, 'start': start, 'end': end}
                         for text, start, end in [('A', 0, 1), ('long', 1, 2), ('book', 2, 305)]]
                (args.output / 'alignment.json').write_text(json.dumps({'requires_review': False,
                    'cues': [{'start': 0, 'end': 305000}], 'alignment': {'segments': [{'words': words}]}}))
            result, review = process(source, work, {'title': 'Long book', 'language': 'en'}, root,
                                     lambda *stage: stages.append(stage), engine=engine)
            self.assertFalse(review)
            with zipfile.ZipFile(result) as archive:
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual(manifest['tracks'][0]['wordTimings'], 'words.json')
                self.assertEqual(manifest['format'], 'foreign-language-learner.book')
                self.assertEqual(json.loads(archive.read('words.json'))['words'][-1]['end'], 305)
            self.assertIn(('aligning', 35), stages)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required')
    def test_chapter_output_preserves_boundaries_and_words(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); audio = root / 'tone.mp3'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440',
                '-t', '2', '-ac', '1', '-ar', '16000', str(audio)], check=True)
            source = root / 'input.zip'
            with zipfile.ZipFile(source, 'w') as archive:
                archive.write(audio, 'one.mp3'); archive.write(audio, 'two.mp3')
                archive.writestr('input.json', json.dumps({'schemaVersion': 1, 'audio': ['one.mp3', 'two.mp3'], 'text': 'text.txt'}))
                archive.writestr('text.txt', 'First chapter. Second chapter.')
                archive.writestr('provenance.json', '{"provider":"Wolne Lektury"}')
            def engine(args):
                args.output.mkdir()
                words = [{'word': w, 'start': start, 'end': end} for w,start,end in [
                    ('First',0,0.5),(' chapter.',0.5,1.5),(' Second',2.1,2.5),(' chapter.',2.5,3.5)]]
                (args.output / 'alignment.json').write_text(json.dumps({'requires_review': False,
                    'cues': [{'start': 0, 'end': 3500}], 'alignment': {'segments': [{'words': words}]}}))
            work = root / 'work'; work.mkdir()
            job = {'title': 'Book', 'language': 'en', 'preserve_chapters': True,
                'source_book': {'source': {'tracks': [{'title': 'One'}, {'title': 'Two'}]}}}
            result, review = process(source, work, job, root, lambda *args: None, engine)
            with zipfile.ZipFile(result) as archive:
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual([t['title'] for t in manifest['tracks']], ['One','Two'])
                self.assertEqual(len({t['audio'] for t in manifest['tracks']}), 2)
                words=[]
                for t in manifest['tracks']:
                    local=json.loads(archive.read(t['wordTimings']))
                    self.assertEqual(local['trackID'], t['id'])
                    self.assertLess(local['words'][-1]['end'],2)
                    words.extend(w['text'] for w in local['words'])
                self.assertEqual(words, ['First','chapter.','Second','chapter.'])
                self.assertIn('provenance.json',archive.namelist())


if __name__ == '__main__':
    unittest.main()
