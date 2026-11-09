"""One Bedrock Converse submission with a bounded read and no SDK retries."""
import json
from backend.translation.contract import canonical, output_schema, validate_output
from backend.translation.provider import CONTEXT_PROMPT, WORD_PROMPT, ProviderFailure

MODEL_ID = 'qwen.qwen3-235b-a22b-2507-v1:0'


class BedrockProvider:
    def __init__(self, client):
        self.client = client

    def run(self, kind, payload):
        # Prompt + server validation avoid Bedrock's first-schema compilation delay (up to 90s),
        # which exceeds this synchronous API's deadline. Never repair via a second paid call.
        prompt = (CONTEXT_PROMPT if kind == 'context' else WORD_PROMPT)
        prompt += '\nReturn JSON without markdown, matching this schema: ' + canonical(output_schema(kind))
        try:
            response = self.client.converse(modelId=MODEL_ID,
                system=[{'text': prompt}], messages=[{'role': 'user', 'content': [{'text': canonical(payload)}]}],
                inferenceConfig={'maxTokens': 2048, 'temperature': 0.1})
        except Exception:
            raise ProviderFailure(unknown=True) from None
        usage = response.get('usage', {})
        tokens = {'input_tokens': int(usage.get('inputTokens', 0)), 'output_tokens': int(usage.get('outputTokens', 0))}
        try:
            if response.get('stopReason') != 'end_turn':
                raise ValueError('Incomplete output')
            raw = ''.join(block.get('text', '') for block in response['output']['message']['content'])
            if len(raw.encode()) > 131072:
                raise ValueError('Oversized output')
            return validate_output(kind, json.loads(raw), payload), tokens
        except Exception:
            raise ProviderFailure(tokens=tokens) from None
