import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name('audio_markup.py')
spec = importlib.util.spec_from_file_location('audio_markup', path)
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


def words(text, offset=0):
    return [{'token': token, 'start': offset+i, 'end': offset+i+0.5}
            for i, token in enumerate(audio.tokens(text))]


class AudioMarkupTests(unittest.TestCase):
    def test_repeated_anchor_keeps_two_occurrences(self):
        phrase = 'Czy jest inny kolor spodni w tym rozmiarze'
        result = audio.find_anchor(words(phrase)+words(phrase, 80), phrase, 2)
        self.assertEqual([x['start'] for x in result], [0, 80])

    def test_missing_repeat_fails_closed(self):
        phrase = 'Czy jest inny kolor spodni w tym rozmiarze'
        with self.assertRaisesRegex(ValueError, 'expected 2'):
            audio.find_anchor(words(phrase), phrase, 2)

    def test_anchor_cannot_bridge_a_repeat_pause(self):
        phrase = 'w wymyslonym przykladzie omawiamy nowe plany naszego zespolu'
        observed = words('w innym zdaniu', 10) + words(phrase, 65)
        matches = audio.find_anchor(observed, phrase, 1)
        self.assertEqual(matches[0]['start'], 65)
        with self.assertRaisesRegex(ValueError, 'expected 2'):
            audio.find_anchor(observed, phrase, 2)

    def test_overlapping_long_anchor_candidates_are_one_occurrence(self):
        phrase = 'w wymyslonym przykladzie omawiamy nowe plany naszego zespolu na jutro'
        observed = words('w innym zdaniu', 10) + words(phrase, 35)
        # A slow phrase can produce a weaker candidate >20s before its real
        # start. Its overlapping words still belong to this single reading.
        observed[2]['end'] = 16
        matches = audio.find_anchor(observed, phrase, 1)
        self.assertEqual(matches[0]['start'], 35)

    def test_anchor_keeps_a_long_pause_around_a_worked_example(self):
        phrase = 'pierwszy fragment zaczyna sie tutaj'
        observed = words(phrase)
        for word in observed[2:]:
            word['start'] += 30
            word['end'] += 30
        match = audio.find_anchor(observed, phrase, 1)[0]
        self.assertEqual(match['end'], observed[-1]['end'])

    def test_search_folds_asr_accents_without_changing_reference(self):
        phrase = 'treningi są dobre dla zawodowców'
        result = audio.find_anchor(words('tręningi są dobry dla zawodowców'), phrase, 1)
        self.assertEqual(result[0]['reference_text'], phrase)
        self.assertGreaterEqual(result[0]['score'], .75)

    def test_task_order_is_enforced(self):
        transcription = {'segments': [{'words': [
            {'word': w['token'], 'start': w['start'], 'end': w['end']}
            for w in words('jeden dwa trzy cztery koniec tego fragmentu tutaj', 10)
        ]}]}
        task = {'task_label': 'I', 'expected_occurrences': 1,
                'start_anchor': 'jeden dwa trzy cztery',
                'end_anchor': 'koniec tego fragmentu tutaj', 'source_refs': []}
        with self.assertRaisesRegex(ValueError, 'unordered'):
            audio.locate({'tasks': [task, dict(task, task_label='II')]}, transcription, 100000)

    def test_zero_length_anchor_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'three words'):
            audio.find_anchor([], 'krótkie słowa', 1)

    def test_end_anchor_rejects_a_missing_final_source_word(self):
        phrase = 'ten fragment jest bardzo dlugi i konczy sie bezpiecznie'
        observed = words('pierwszy fragment zaczyna sie', 1) + words(
            'ten fragment jest bardzo dlugi i konczy sie bardzo', 10)
        task = {'task_label': 'I', 'expected_occurrences': 1,
                'start_anchor': 'pierwszy fragment zaczyna sie',
                'end_anchor': phrase, 'source_refs': []}
        transcript = {'segments': [{'words': [
            {'word': word['token'], 'start': word['start'], 'end': word['end']}
            for word in observed]}]}
        with self.assertRaisesRegex(ValueError, 'expected 1 occurrences'):
            audio.locate({'tasks': [task]}, transcript, 40000)

    def test_end_anchor_preserves_exact_concatenated_word_splits(self):
        phrase = 'ostatni fragment konczy sie autobusowy'
        observed = words('ostatni fragment konczy sie autobusow y', 10)
        match = audio.find_anchor(observed, phrase, 1, require_last_token=True)[0]
        self.assertEqual(match['match_policy'], 'exact_concatenated_tokens')
        self.assertEqual(match['end'], observed[-1]['end'])

    def test_long_source_passage_keeps_its_original_bounds(self):
        task = {'task_label': 'I', 'expected_occurrences': 1,
                'start_anchor': 'pierwszy komunikat zaczyna sie',
                'end_anchor': 'ostatni komunikat konczy sie', 'source_refs': []}
        transcript = {'segments': [{'words': [
            {'word': w['token'], 'start': w['start'], 'end': w['end']}
            for w in words(task['start_anchor'], 160) + words(task['end_anchor'], 713)
        ]}]}
        occurrence = audio.locate({'tasks': [task]}, transcript, 900000)[0]['occurrences'][0]
        self.assertEqual((occurrence['start_ms'], occurrence['end_ms']), (159250, 717250))
        with self.assertRaisesRegex(ValueError, 'original audio bounds'):
            audio.locate({'tasks': [task]}, transcript, 700000)

    def test_reordered_tasks_fail_even_when_both_passages_exist(self):
        first = 'pierwszy fragment zaczyna sie teraz tutaj pierwszy fragment konczy sie teraz'
        second = 'drugi fragment zaczyna sie teraz tutaj drugi fragment konczy sie teraz'
        transcript = {'segments': [{'words': [
            {'word': w['token'], 'start': w['start'], 'end': w['end']}
            for w in words(first, 10)+words(second, 80)
        ]}]}
        tasks = [{'task_label': label, 'expected_occurrences': 1,
                  'start_anchor': f'{name} fragment zaczyna sie',
                  'end_anchor': f'{name} fragment konczy sie teraz', 'source_refs': []}
                 for label, name in [('I','pierwszy'), ('II','drugi')]]
        with self.assertRaisesRegex(ValueError, 'unordered'):
            audio.locate({'tasks': tasks[::-1]}, transcript, 200000)

    def test_unrelated_text_does_not_get_invented_timestamps(self):
        with self.assertRaisesRegex(ValueError, 'found 0'):
            audio.find_anchor(words('To zupełnie inna wypowiedź o pogodzie'),
                              'Książki trzeba oddać przed końcem miesiąca', 1)

    def test_reference_text_mismatch_is_reported(self):
        result = {'alignment': {'segments': [{'words': [
            {'word': 'inne słowo', 'start': 0, 'end': 1}]}]}}
        self.assertFalse(audio.alignment_quality(result, 'oficjalny tekst')['text_matches_reference'])


if __name__ == '__main__':
    unittest.main()
