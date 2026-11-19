import unittest
from audio_markup import find_anchor


def words(text):
    return [{'token': token, 'start': i, 'end': i + .5}
            for i, token in enumerate(text.split())]


class AnchorRecoveryTests(unittest.TestCase):
    def test_first_token_typo_still_requires_full_threshold(self):
        hit = find_anchor(words('wedlok analitykow w najblizszych latach'),
                          'wedlug analitykow w najblizszych latach', 1)[0]
        self.assertEqual(hit['start'], 0)
        self.assertFalse(hit['first_token_exact'])
        self.assertGreaterEqual(hit['score'], .75)

    def test_near_first_word_does_not_admit_unrelated_phrase(self):
        with self.assertRaises(ValueError):
            find_anchor(words('wedlok obcy tekst zupelnie inny'),
                        'wedlug analitykow w najblizszych latach', 1)

    def test_exact_split_word_preserves_actual_range_and_text(self):
        hit = find_anchor(words('potrafisz zrobic naprawde wysmieni te pierogi'),
                          'potrafisz zrobic naprawde wysmienite pierogi', 1)[0]
        self.assertEqual(hit['match_policy'], 'exact_concatenated_tokens')
        self.assertEqual(hit['end'], 5.5)
        self.assertEqual(hit['observed_text'], 'potrafisz zrobic naprawde wysmieni te pierogi')

    def test_concat_does_not_accept_changed_lexical_content(self):
        with self.assertRaises(ValueError):
            find_anchor(words('potrafisz uszyc naprawde wysmieni te ubrania'),
                        'potrafisz zrobic naprawde wysmienite pierogi', 1)

    def test_repeat_count_remains_strict(self):
        with self.assertRaises(ValueError):
            find_anchor(words('potrafisz zrobic naprawde wysmieni te pierogi'),
                        'potrafisz zrobic naprawde wysmienite pierogi', 2)

    def test_three_word_anchor_retains_minimum(self):
        self.assertEqual(len(find_anchor(words('dlaczego zostalas stewardessa'),
                                        'dlaczego zostalas stewardessa', 1)), 1)
        with self.assertRaises(ValueError):
            find_anchor(words('dlaczego zostalas'), 'dlaczego zostalas', 1)
