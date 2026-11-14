"""Versioned, bounded subscription inputs and outputs (all offsets use UTF-16)."""
import hashlib
import json
from backend.cloud.errors import CloudError

LANGUAGES = {'en', 'fr', 'es', 'de', 'it', 'pl'}
POLICY_VERSION = 'cloud-v1'

# Keep this allowlist aligned with OpenAITranslationModel; clients cannot choose arbitrary models.
MODEL_REASONING = {
    'gpt-5-mini': ('minimal', 'low', 'medium', 'high'),
    'gpt-5-nano': ('minimal', 'low', 'medium', 'high'),
    'gpt-6-luna': ('none', 'low', 'medium', 'high', 'xhigh', 'max'),
    'gpt-6.1-terra': ('none', 'low', 'medium', 'high', 'xhigh', 'max'),
    'gpt-6.1-sol': ('low', 'medium', 'high', 'xhigh', 'max'),
}


def inference_settings(value, default_model='gpt-5-mini'):
    model = value.get('model', default_model)
    if not isinstance(model, str) or model not in MODEL_REASONING:
        raise CloudError('INVALID_MODEL')
    default_effort = 'minimal' if model in {'gpt-5-mini', 'gpt-5-nano'} else ('none' if model == 'gpt-6-luna' else 'medium')
    effort = value.get('reasoning_effort', default_effort)
    if not isinstance(effort, str) or effort not in MODEL_REASONING[model]:
        raise CloudError('INVALID_REASONING')
    return model, effort


def units(text):
    try:
        return len(text.encode('utf-16-le')) // 2
    except UnicodeError:
        raise CloudError('INVALID_UNICODE') from None


def text(value, limit):
    if not isinstance(value, str) or not value.strip() or units(value) > limit:
        raise CloudError('INVALID_TEXT')
    return value


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def validate_input(kind, value):
    common = {'schema_version', 'selected_text', 'context', 'selection_location_utf16',
              'selection_length_utf16', 'source_language', 'target_language'}
    extra = {'words_to_explain'} if kind == 'context' else {'lemma'}
    optional = {'model', 'reasoning_effort'}
    if (kind not in {'context', 'word'} or not isinstance(value, dict)
            or not (common | extra).issubset(value) or set(value) - (common | extra | optional)
            or ((set(value) & optional) not in (set(), optional))):
        raise CloudError('INVALID_REQUEST')
    inference_settings(value)
    if type(value['schema_version']) is not int or value['schema_version'] != 1:
        raise CloudError('UNSUPPORTED_SCHEMA')
    phrase_only = kind == 'context' and value.get('words_to_explain') == []
    selected = text(value['selected_text'], 1400 if phrase_only else 256)
    context = text(value['context'], 1400)
    location, length = value['selection_location_utf16'], value['selection_length_utf16']
    if type(location) is not int or type(length) is not int or location < 0 or length <= 0 or length != units(selected):
        raise CloudError('INVALID_SELECTION')
    try:
        actual = context.encode('utf-16-le')[location * 2:(location + length) * 2].decode('utf-16-le')
    except UnicodeError:
        raise CloudError('INVALID_SELECTION') from None
    if actual != selected:
        raise CloudError('INVALID_SELECTION')
    if not isinstance(value['source_language'], str) or value['source_language'] not in LANGUAGES or value['target_language'] != 'ru':
        raise CloudError('INVALID_LANGUAGE')
    if kind == 'word':
        text(value['lemma'], 256)
    else:
        words = value['words_to_explain']
        # The client owns function-word exclusion. Accept only an ordered bounded subsequence
        # of exact whitespace-delimited source tokens, preserving repeated occurrences.
        if not isinstance(words, list) or len(words) > 128:
            raise CloudError('INVALID_WORDS')
        tokens = iter(selected.split())
        for word in words:
            text(word, 256)
            if not any(token == word for token in tokens):
                raise CloudError('INVALID_WORDS')
    return value


def validate_output(kind, value, request):
    if not isinstance(value, dict):
        raise CloudError('INVALID_OUTPUT')
    try:
        if kind == 'word':
            if set(value) != {'definition', 'meaningInContext', 'examples'}:
                raise CloudError('INVALID_OUTPUT')
            text(value['definition'], 1200); text(value['meaningInContext'], 700)
            examples = value['examples']
            if not isinstance(examples, list) or not 1 <= len(examples) <= 2:
                raise CloudError('INVALID_OUTPUT')
            for example in examples:
                if not isinstance(example, dict) or set(example) != {'phrase', 'translation'}:
                    raise CloudError('INVALID_OUTPUT')
                text(example['phrase'], 300); text(example['translation'], 400)
        else:
            if set(value) != {'phrase_translation', 'word_explanations'}:
                raise CloudError('INVALID_OUTPUT')
            text(value['phrase_translation'], 2800 if request.get('words_to_explain') == [] else 512)
            rows = value['word_explanations']
            expected = request['words_to_explain']
            if not isinstance(rows, list) or len(rows) != len(expected):
                raise CloudError('INVALID_OUTPUT')
            lines = []
            for row, word in zip(rows, expected):
                if not isinstance(row, dict) or set(row) != {'source_word', 'lemma', 'meaning'} or row['source_word'] != word:
                    raise CloudError('INVALID_OUTPUT')
                for key in row:
                    text(row[key], 2000)
                    if '\n' in row[key] or '\r' in row[key] or ' — ' in row[key]:
                        raise CloudError('INVALID_OUTPUT')
                lines.append(f"{word} — {row['lemma']} — {row['meaning']}")
            if units('\n\n'.join(lines)) > 2000:
                raise CloudError('INVALID_OUTPUT')
    except (KeyError, TypeError):
        raise CloudError('INVALID_OUTPUT') from None
    return value


def object_schema(properties):
    return {'type': 'object', 'additionalProperties': False, 'properties': properties, 'required': list(properties)}


def output_schema(kind):
    string = {'type': 'string'}
    if kind == 'context':
        return object_schema({'phrase_translation': string, 'word_explanations': {'type': 'array',
            'items': object_schema({key: string for key in ['source_word', 'lemma', 'meaning']})}})
    return object_schema({'definition': string, 'meaningInContext': string, 'examples': {'type': 'array',
        'minItems': 1, 'maxItems': 2, 'items': object_schema({'phrase': string, 'translation': string})}})
