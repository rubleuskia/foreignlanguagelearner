# Per-request translation settings

Both POST /v1/context-analyses and POST /v1/word-explanations accept an optional pair:

```json
{"model": "gpt-5-mini", "reasoning_effort": "low"}
```

These are top-level fields alongside the unchanged schema_version 1 text/range/language fields.
Send both or neither; old requests keep their existing assembly defaults. Arbitrary models,
unsupported model/effort combinations, extra fields and client-defined output budgets fail before
admission. The allowed model/effort table lives in backend/translation/contract.py and mirrors
OpenAITranslationModel. Subscription workers persist and use the pair selected at admission.

The app's model/reasoning selectors apply to personal-key and configured subscription requests.
Custom prompts and personal keys are not sent to the backend. The source label and payload use
the same settings snapshot: Direct to OpenAI, Via cloud backend, or On device for Apple Translation.

Changing model/effort changes the request fingerprint. Reusing an idempotency key with different
settings returns a conflict; unknown historical requests are never automatically resubmitted.
The cloud service retains its existing token, deadline and admission limits. Selecting expensive
models/reasoning does not increase those limits, prove model access, or guarantee completion.
This contract/UI change requires a new backend release to accept the new fields and an app update.
It does not configure/deploy subscriptions or connect private-operator translation UI by itself.
