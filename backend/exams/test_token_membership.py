import copy
import unittest

from backend.exams.contract import ExamError, grade_sections, validate_response
from backend.exams.token_membership import tokens, validate_membership


class TokenMembershipTests(unittest.TestCase):
    def row(self):
        return {'id':'listening-III-2','response_type':'text','max_score_units':200,
                'grading':{'mode':'token_membership','accepted_answers':['A','C'],
                           'token_pattern':'[A-D]','max_tokens':2,'ignore_case':True}}

    def score(self, answer):
        row=self.row()
        exam={'id':'test','revision':'revision','sections':[
            {'id':'listening','max_score_units':200,'tasks':[{'id':'listening-III','items':[row]}]}]}
        return grade_sections(exam,{row['id']:answer},['listening'])['sections'][0]['objective_score_units']

    def test_source_letters_partial_credit_order_deduplication_and_case(self):
        self.assertEqual(self.score('C / A'),200)
        self.assertEqual(self.score('c,a'),200)
        self.assertEqual(self.score('A A a'),100)
        self.assertEqual(self.score('A; B'),100)
        self.assertEqual(self.score(''),0)

    def test_all_wrong_letters_count_against_source_capacity(self):
        with self.assertRaises(ExamError) as error:
            validate_response(self.row(),'A B C D')
        self.assertEqual(error.exception.code,'TOO_MANY_EXAM_TOKENS')

    def test_unicode_lookalikes_do_not_match_source_ascii_letters(self):
        self.assertEqual(self.score('А Ｃ'),0)  # Cyrillic A and fullwidth C.
        self.assertEqual(tokens('K',{'token_pattern':'[A-Z]','ignore_case':True}),set())

    def test_existing_numeric_source_format_is_unchanged(self):
        grading={'accepted_answers':['1','12'],'max_tokens':2}
        self.assertEqual(tokens('１２ / 1 / 12 / 1',grading),{'1','12'})
        row=self.row();row['grading']=grading
        validate_membership(row)

    def test_invalid_source_rules_are_rejected(self):
        variants=[{'token_pattern':'.*'}, {'token_pattern':'[Z-A]'},
                  {'accepted_answers':['A','a']}, {'accepted_answers':['A','Ё']},
                  {'max_tokens':3},{'max_tokens':True}]
        for update in variants:
            row=self.row();row['grading'].update(update)
            with self.subTest(update=update),self.assertRaises(ValueError):validate_membership(row)
        row=self.row();row['max_score_units']=75
        with self.assertRaises(ValueError):validate_membership(row)


if __name__=='__main__':unittest.main()
