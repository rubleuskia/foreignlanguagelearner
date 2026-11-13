"""Lazy server credential loading and one bounded OpenAI Responses submission."""
import json
from backend.translation.provider import OpenAIProvider, ProviderFailure
from backend.translation.contract import inference_settings

MODEL_ID = 'gpt-5-mini'


class OperatorProvider:
    def __init__(self, secrets, secret_arn, opener=None):
        self.secrets, self.secret_arn, self.opener = secrets, secret_arn, opener
        self.provider = None

    def run(self, kind, payload):
        model, effort = inference_settings(payload)
        # Health/login/alignment never retrieve the model key. Cache only in this warm process.
        if self.provider is None:
            try:
                value = self.secrets.get_secret_value(SecretId=self.secret_arn)
                key = json.loads(value['SecretString'])['api_key']
                if not isinstance(key, str) or not key.strip() or key != key.strip():
                    raise ValueError('Invalid provider credential')
                self.provider = OpenAIProvider(key, self.opener, timeout=18)
            except Exception:
                # No external model submission occurred; do not expose secret/service messages.
                raise ProviderFailure() from None
        return self.provider.run(kind, payload, model, 2048, effort)
