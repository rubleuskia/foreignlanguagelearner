"""Synthetic exam material for tests; never copied from an examination paper."""
from __future__ import annotations


def synthetic_profile():
    paper = [{'source_id': 'paper', 'page': 1}]
    keys = [{'source_id': 'keys', 'page': 1}]

    def item(task_id, number, score=50, mode='exact', accepted=None):
        return {'id': f'{task_id}-{number}', 'label': str(number), 'position': number,
                'prompt': f'Synthetic response {number}', 'response_type': 'text',
                'option_ids': [], 'max_score_units': score, 'source_refs': paper,
                'grading': {'mode': mode, 'accepted_answers': accepted or ['sample'],
                            'source_refs': keys}}

    def task(task_id, label, position, items, options=None):
        return {'id': task_id, 'label': label, 'position': position,
                'instruction': 'Complete this synthetic test task.',
                'interaction_type': 'gap_text', 'max_score_units': sum(i['max_score_units'] for i in items),
                'source_refs': paper, 'blocks': [], 'options': options or [], 'items': items}

    listening = [task(f'listening-{label}', label, n, [item(f'listening-{label}', 1)])
                 for n, label in enumerate(['I', 'II', 'III', 'IV'], 1)]
    tokens = item('listening-V', 1, 200, 'token_membership', ['1', '2'])
    tokens['grading']['max_tokens'] = 2
    listening.append(task('listening-V', 'V', 5, [tokens]))
    choice = item('reading-I', 1)
    choice['response_type'] = 'single_choice'
    choice['option_ids'] = ['reading-I-option-1-a', 'reading-I-option-1-b']
    choice['grading']['accepted_answers'] = ['reading-I-option-1-b']
    reading = [task('reading-I', 'I', 1, [choice], [
        {'id': value, 'label': label, 'text': f'Synthetic option {label}', 'source_refs': paper}
        for label, value in zip(['a', 'b'], choice['option_ids'])])]
    grammar = [task('grammar-IV', 'IV', 1, [item('grammar-IV', 1)])]
    for position, label, score in [(1, 'V', 50), (2, 'VI', 100)]:
        items = [item(f'grammar-{label}', n, score, 'ai_stub') for n in range(1, 6)]
        for value in items:
            value['grading'].update(accepted_answers=[], reference_answer='Synthetic reference', rubric={
                'text': 'Synthetic rubric: award justified components in quarter-point steps.',
                'source_text': 'Synthetic rubric', 'source_refs': keys})
        grammar.append(task(f'grammar-{label}', label, position + 1, items))
    ambiguous = grammar[1]['items'][3]['grading']
    ambiguous['reference_answer'] = 'Synthetic component (0,25)'
    ambiguous['rubric']['interpretation_status'] = 'needs_review'
    sections = []
    for position, section_id, tasks in [(1, 'listening', listening), (2, 'reading', reading), (3, 'grammar', grammar)]:
        sections.append({'id': section_id, 'title': section_id, 'position': position,
                         'time_limit_seconds': 2400, 'max_score_units': sum(t['max_score_units'] for t in tasks),
                         'source_refs': paper, 'tasks': tasks})
    for position, section_id in [(4, 'writing'), (5, 'speaking')]:
        sections.append({'id': section_id, 'title': section_id, 'position': position,
                         'status': 'source_missing', 'max_score_units': 0, 'source_refs': paper, 'tasks': []})
    return {'schema_version': '1.1', 'id': 'synthetic-exam', 'title': 'Synthetic exam fixture',
            'language': 'pl', 'level': 'B1', 'audience': 'adults',
            'session': {'year': 2024, 'label': 'Synthetic session', 'start_date': '2024-01-01',
                        'end_date': '2024-01-02'}, 'sections': sections,
            'source_refs': paper, 'interactive_section_ids': ['listening', 'reading', 'grammar']}
