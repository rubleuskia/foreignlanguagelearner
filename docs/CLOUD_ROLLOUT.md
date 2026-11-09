# Cloud rollout in two stages

Updated: 2026-11-09. Status: operator assembly and dashboard implementation prepared; not deployed.

This rollout supersedes the Apple-first deployment order in PAID_CLOUD_BACKEND_PLAN.md.
The existing subscription implementation remains available as stage-two code, not a prerequisite
for the first usable backend. The dashboard now has a separate operator assembly; publishing requires a new verified CI-tag
containing that implementation. Older tags still build the subscription configuration. See the
[operator publication guide](OPERATOR_CLOUD.md) for implemented contracts and remaining prerequisites.

## Stage 1 — private operator backend

One manually provisioned application user can use translations, word explanations and audio/text
alignment without Apple registration, products, purchase verification or subscription allowances.
All Regional resources stay in eu-north-1. This is application access, not AWS administrator access.

| Component | Infrastructure | Responsibility |
|---|---|---|
| Login | Cognito User Pool and public native app client | Username/password login, access/refresh tokens; self-registration disabled. Operator manually creates the sole user in the AWS console and completes initial password setup. |
| API | API Gateway HTTP API with JWT authorizer | Authenticate service routes, rate-limit traffic; validate access-token scope, audience and issuer. Handlers enforce the configured operator subject; another valid pool user is not automatically an operator. |
| Translations and explanations | Python Lambda calling a configured model provider directly | Validate bounded text input, execute one model call and validate structured JSON output. No SQS, stream dispatcher or inference maintenance queue on this path. |
| Request records | Small DynamoDB table with expiry | Record idempotency key, input fingerprint, submission state and bounded result. Persist the submission boundary before calling the model; return the known result on replay. An unknown outcome does not trigger automatic paid resubmission. No subscription tables or monthly allowance accounting. |
| Alignment API | Python Lambda behind the same JWT authorizer | Create jobs, issue scoped temporary upload/download URLs, start, inspect and cancel jobs. No anonymous creation route. |
| Alignment files/state | Private S3 and DynamoDB | Temporary audio/TXT, subtitles and diagnostics; job state, admission/concurrency counters and expiry. Files transfer directly to S3 through signed URLs. |
| Alignment compute | Step Functions Standard, ECS Fargate CPU worker, ECR image, VPC | Run the long audio job once, finalize outputs, handle timeout/cancellation and reconcile interrupted jobs. No always-running worker or NAT gateway is required by the existing design. |
| Monitoring | CloudWatch Logs/metrics/alarms and SNS | API failures/latency, Lambda errors/throttles, model failures/latency/token counts and alignment failures/timeouts; an explicitly subscribed operator receives alerts. Never log passwords, tokens, model keys or source text/results. |

### Authentication boundary

The password goes to Cognito over TLS at sign-in; subsequent API calls carry an access token.
API Gateway does not store or verify a custom password on every API request. The operator has
access to every stage-one feature and its data, but runtime Lambda/task roles retain only their
necessary AWS permissions. Use a stable configured Cognito subject for operator authorization.
Token refresh, expiry, first-login password challenge and sign-out must be covered in the client.
Manually created users beyond that subject must be denied by handlers.

### Direct model request and time limits

The target path is client → API Gateway → Lambda → model → JSON response. HTTP APIs have a fixed
30-second maximum integration timeout. Use an end-to-end budget below that limit (initial target:
25 seconds total), bounded model output and no automatic retry of a submitted inference.
The existing OpenAI provider's 45-second network timeout cannot be reused unchanged.

An idempotency record protects against repeated paid submission after client disconnect. Return
completed results by request ID/key; an in-progress or outcome-unknown operation must not cause a
second call. This lightweight recovery is separate from the stage-two paid reservation ledger.
If measured latency cannot fit, explicitly revise the API transport/job contract rather than
silently keeping a 45-second call behind a 30-second gateway. SQS is not part of the initial target.

The current SQS pipeline exists for durable asynchronous execution and subscription reservation
settlement; a single external model call alone does not require a queue. Long alignment work still
uses an asynchronous job API because it cannot finish within one HTTP request.

### Selected provider and model

The operator selected Amazon Bedrock. Use Qwen3 235B A22B Instruct 2507 as the stage-one default:
`qwen.qwen3-235b-a22b-2507-v1:0`, `bedrock-runtime` Converse, direct eu-north-1 ON_DEMAND,
Standard tier. Scope the Lambda role to this model; no external OpenAI key or cross-Region profile.
Keep the provider interface and existing server-side validated input/output contracts.

Selection rationale: Qwen lists Polish and Russian among its supported languages; AWS documents
regional access and structured outputs. This is an initial engineering choice, not a measured claim
that it outperforms every alternative for Polish/Russian. Prioritize Polish → Russian context,
idioms, inflected lemmas and natural examples. Model-level Polish ↔ Russian support does not change
the existing application's six-source-language/Russian-target contract by itself.

Live checks on 2026-11-09 returned ACTIVE/ON_DEMAND and availability AUTHORIZED/AVAILABLE.
However, the attempted six-example Converse evaluation was rejected with AccessDeniedException:
AWS says the project is currently being verified, normally less than two hours. No model result,
quality, JSON compliance or latency was verified. Do not bypass this with another Region. After
verification, run the bounded Polish/Russian evaluation and deadline/schema checks before acceptance.

Official AWS Price List for eu-north-1 on 2026-11-09 lists Standard on-demand rates of $0.22 per
million input tokens and $0.88 per million output tokens. For 1,000 input + 500 output tokens this
is $0.00066 for the model alone, excluding AWS API/compute/storage charges and tax. Recheck prices
before deployment; no spending or throughput guarantee follows from this estimate.

Read-only Bedrock discovery on 2026-11-09 in eu-north-1 returned these examples:

| Access shown by the catalogue | Example text models |
|---|---|
| Direct ON_DEMAND | Amazon Nova Lite v1; OpenAI gpt-oss-20b/120b; Qwen3 32B/235B; DeepSeek V3/V3.2; GLM 4.7/5; Kimi K2.5; MiniMax M2.5 |
| INFERENCE_PROFILE only | Claude Haiku/Sonnet/Opus families; Amazon Nova Pro/Nova 2 Lite; proprietary OpenAI GPT families |

Catalogue presence is not proof of inference permission, quota, structured-output support or
language quality. Listed EU/global profiles route outside the selected Region and are unsuitable
for this project's current single-Region restriction. Do not select them simply because listing
from eu-north-1 succeeds. Model/access discovery must be refreshed before implementation.

For acceptance, evaluate the selected Qwen model on Polish/Russian first and the other supported
source languages before claiming full existing-language coverage. Check
meaning, contextual lemma, natural independent examples, exact JSON contract, latency and token
cost. Preserve server-side schema validation even where the model offers structured outputs.
The first inference attempt was refused by AWS project verification; no successful inference ran.

### Implementation order and acceptance

1. Separate stage-one CDK assembly/configuration and dashboard status from the Apple/billing
   assembly. Preparation requires no Apple IDs, secrets, products or policy of subscription benefits.
   Preserve verified-main-tag preparation/deployment and reviewable plans for the new assembly.
2. Provision Cognito and protected API. Operator creates the user manually. Verify login, refresh,
   invalid/expired token rejection and rejection of a different authenticated subject.
3. Adapt translations/explanations to direct requests and minimal request records. Validate the
   provider, schema, deadline, repeated-key recovery and disconnect/unknown-outcome behavior.
4. Adapt alignment to operator authorization without subscription dependencies. Build and publish
   the immutable worker image; measure actual runtime/memory/cost and six-language quality before
   enabling real jobs. Verify upload/start/result/cancel/expiry and interruption recovery.
5. Connect alarms and operator notifications, configure retention and cost/concurrency bounds,
   run live smoke and explicitly bounded inference/audio acceptance, and connect the native client.

Global rate/concurrency/cost controls remain in stage one despite the absence of subscription
quotas. Stage one is complete only when the operator can sign in, translate/explain and align real
audio, inspect diagnostics and receive an exercised monitoring notification. Deployment alone is
not acceptance. Keep created resources for use; cleanup remains an explicit operator choice.

## Stage 2 — public accounts and paid service

- Add grouped Sign in with Apple, native account recovery and deletion/consent revocation handling.
- Add App Store Connect products, StoreKit purchase/restore and server-side verification.
- Add Apple purchase and identity webhooks, durable inbox/reconciliation and retry queues.
- Add per-account ownership/isolation, entitlements, subscription periods and monthly allowances.
- Restore the full usage reservation/settlement and support/refund/recovery rules for paid work.
- Reassess asynchronous inference/SQS against measured latency and paid-service recovery needs.
- Complete production policy, privacy/support pages, sandbox purchase and production release checks.

Keep the privileged operator identity separate from ordinary customers. Replacing auth must not
expose operator data, grant global access to every Apple login, or silently remap stored ownership.
Define the operator/data migration before enabling multi-user signup. Stage-two changes must not
require destructive replacement of stage-one files or request history.

## References

- [HTTP API quotas: fixed 30-second timeout](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-quotas.html)
- [Bedrock model catalogue](https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html)
- [Bedrock model access prerequisites](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Bedrock structured outputs](https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html)
- [Services and single-Region constraints for this AWS experience](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html)

- [Qwen multilingual language list](https://qwenlm.github.io/blog/qwen3/)
- [Selected model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-235b-a22b-2507.html)
- [Stockholm price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonBedrock/current/eu-north-1/index.json)
