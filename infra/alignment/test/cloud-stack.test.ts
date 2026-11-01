import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { Template } from "aws-cdk-lib/assertions";
import { CloudTranslationStack } from "../lib/translation-stack";
import { AlignmentStack } from "../lib/alignment-stack";
import { CloudFoundationStack, CloudBillingStack } from "../lib/cloud-stack";

const asset = fs.mkdtempSync(path.join(os.tmpdir(), "fll-cloud-stack-"));
fs.writeFileSync(path.join(asset, "index.py"), "def handler(event, context): pass\n");
for (const stage of ["dev", "prod"] as const) {
  const app = new cdk.App();
  const code = () => lambda.Code.fromAsset(asset);
  const env = { account: "111111111111", region: "eu-central-1" };
  const foundation = new CloudFoundationStack(app, `Foundation-${stage}`, {
    env, stage, code: code(), appleClientId: "app.login", appleTeamId: "TEAMID", appleKeyId: "KEYID",
    appleSignInSecretArn: "arn:aws:secretsmanager:eu-central-1:111111111111:secret:apple-login-AbCdEf",
    callbackUrl: "fll://auth", domainPrefix: `fll-test-${stage}`,
  });
  const billing = new CloudBillingStack(app, `Billing-${stage}`, {
    env, code: code(), foundation, appleApiSecretArn: "arn:aws:secretsmanager:eu-central-1:111111111111:secret:apple-api-AbCdEf",
    bundleId: "com.rubleuskia.foreignlanguagelearner", appAppleId: "123456789", products: ["monthly"],
  });
  const translation = new CloudTranslationStack(app, `Translation-${stage}`, {
    env, code: code(), foundation,
    openaiSecretArn: "arn:aws:secretsmanager:eu-central-1:111111111111:secret:provider-AbCdEf",
  });
  // Synthesize the entire assembly to detect cross-stack dependency cycles too.
  app.synth();
  const base = Template.fromStack(foundation);
  const bill = Template.fromStack(billing);
  base.resourceCountIs("AWS::Cognito::UserPool", 1);
  base.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 1);
  base.resourceCountIs("AWS::DynamoDB::Table", 3);
  bill.resourceCountIs("AWS::DynamoDB::Table", 1);
  base.hasResourceProperties("AWS::Cognito::UserPoolClient", {
    GenerateSecret: false, EnableTokenRevocation: true, AllowedOAuthFlows: ["code"],
    SupportedIdentityProviders: ["SignInWithApple"], AccessTokenValidity: 15,
  });
  for (const template of [base, bill]) {
    template.resourceCountIs("AWS::EC2::NatGateway", 0);
    template.resourceCountIs("AWS::ECS::TaskDefinition", 0);
    for (const resource of Object.values(template.toJSON().Resources) as any[]) {
      if (resource.Type === "AWS::DynamoDB::Table") {
        assert.equal(resource.DeletionPolicy, "Retain");
        if (["counter_id", "event_id"].includes(resource.Properties.KeySchema[0].AttributeName)) {
          assert.equal(resource.Properties.TimeToLiveSpecification.AttributeName, "delete_after");
        } else assert.equal(resource.Properties.TimeToLiveSpecification, undefined);
        assert.equal(resource.Properties.PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled, true);
      }
      if (resource.Type === "AWS::ApiGatewayV2::Route") {
        const publicWebhook = ["POST /v1/webhooks/apple", "POST /v1/webhooks/apple-identity"].includes(resource.Properties.RouteKey);
        assert.equal(resource.Properties.AuthorizationType, publicWebhook ? "NONE" : "JWT");
        if (!publicWebhook) assert.deepEqual(resource.Properties.AuthorizationScopes, ["paid-cloud/access"]);
      }
    }
  }
  const ai = Template.fromStack(translation);
  ai.resourceCountIs("AWS::EC2::NatGateway", 0);
  ai.resourceCountIs("AWS::ECS::TaskDefinition", 0);
  ai.resourceCountIs("AWS::ApiGatewayV2::Route", 5);
  ai.hasResourceProperties("AWS::DynamoDB::Table", { PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: false },
    TimeToLiveSpecification: { AttributeName: "delete_after", Enabled: true } });
  const resources = ai.toJSON().Resources;
  const rolesWithProviderRead = Object.values(resources).filter((r: any) => r.Type === "AWS::IAM::Policy" &&
    JSON.stringify(r.Properties.PolicyDocument).includes("secretsmanager:GetSecretValue")) as any[];
  assert.equal(rolesWithProviderRead.length, 1);
  const inference = Object.values(resources).find((r: any) => r.Type === "AWS::Lambda::Function" &&
    r.Properties.Handler === "backend.translation.worker.worker_handler") as any;
  assert.deepEqual(rolesWithProviderRead[0].Properties.Roles, [{ Ref: inference.Properties.Role["Fn::GetAtt"][0] }]);
  for (const r of Object.values(resources) as any[]) {
    if (r.Type === "AWS::ApiGatewayV2::Route") assert.equal(r.Properties.AuthorizationType, "JWT");
  }
  assert.equal(foundation.common.ACCEPT_TRANSLATIONS, "false");
  assert.equal(foundation.common.ACCEPT_ALIGNMENTS, "false");
  const billingResources = bill.toJSON().Resources;
  const webhookEntry = Object.entries(billingResources).find(([, r]: [string, any]) =>
    r.Type === "AWS::Lambda::Function" && r.Properties.Handler === "backend.billing.api.webhook_handler")!;
  const webhookRole = (webhookEntry[1] as any).Properties.Role["Fn::GetAtt"][0];
  const webhookPolicies = Object.values(billingResources).filter((r: any) =>
    r.Type === "AWS::IAM::Policy" && r.Properties.Roles.some((role: any) => role.Ref === webhookRole));
  const policy = JSON.stringify(webhookPolicies);
  assert.match(policy, /dynamodb:PutItem/);
  assert.doesNotMatch(policy, /secretsmanager:GetSecretValue|dynamodb:UpdateItem|dynamodb:GetItem/);
  assert.equal((webhookEntry[1] as any).Properties.Environment.Variables.APPLE_API_SECRET_ARN, undefined);
  bill.hasResourceProperties("AWS::Lambda::EventSourceMapping", { FunctionResponseTypes: ["ReportBatchItemFailures"], BatchSize: 1 });
  bill.hasResourceProperties("AWS::Events::Rule", { ScheduleExpression: "rate(5 minutes)" });
  assert.equal(foundation.common.APPLE_ENVIRONMENT, stage === "dev" ? "Sandbox" : "Production");
}
const paidApp = new cdk.App({ context: { workerRepositoryName: "alignment-worker", workerImageDigest: `sha256:${"a".repeat(64)}` } });
const paidFoundation = new CloudFoundationStack(paidApp, "PaidFoundation", {
  env: { account: "111111111111", region: "eu-central-1" }, stage: "dev", code: lambda.Code.fromAsset(asset),
  appleClientId: "app", appleTeamId: "team", appleKeyId: "key", domainPrefix: "paid-test", callbackUrl: "fll://auth",
  appleSignInSecretArn: "arn:aws:secretsmanager:eu-central-1:111111111111:secret:login-AbCdEf",
});
assert.throws(() => new AlignmentStack(paidApp, "NoBenchmark", {
  env: { region: "eu-central-1" }, paidFoundation, cloudCode: lambda.Code.fromAsset(asset),
}), /benchmark/);
// Independent app: a failed construct must not be synthesized. This is synthetic test data only.
const measuredApp = new cdk.App({ context: { workerRepositoryName: "alignment-worker", workerImageDigest: `sha256:${"a".repeat(64)}` } });
const measuredFoundation = new CloudFoundationStack(measuredApp, "MeasuredFoundation", {
  env: { account: "111111111111", region: "eu-central-1" }, stage: "dev", code: lambda.Code.fromAsset(asset),
  appleClientId: "app", appleTeamId: "team", appleKeyId: "key", domainPrefix: "measured-test", callbackUrl: "fll://auth",
  appleSignInSecretArn: "arn:aws:secretsmanager:eu-central-1:111111111111:secret:login-AbCdEf",
});
const paid = new AlignmentStack(measuredApp, "PaidAlignment", {
  env: { account: "111111111111", region: "eu-central-1" }, paidFoundation: measuredFoundation,
  cloudCode: lambda.Code.fromAsset(asset), benchmarkReport: { workerImageDigest: `sha256:${"a".repeat(64)}`,
    maxJobCostUsd: 1, languages: Object.fromEntries(["en","fr","es","de","it","pl"].map(l =>
      [l, { qualityAccepted: true, runtimeSeconds: 100, peakMemoryMiB: 1024, costUsd: 0.1 }])) },
});
measuredApp.synth();
const paidTemplate = Template.fromStack(paid);
paidTemplate.resourceCountIs("AWS::ApiGatewayV2::Api", 0);
paidTemplate.resourceCountIs("AWS::ApiGatewayV2::Route", 9);
for (const resource of Object.values(paidTemplate.toJSON().Resources) as any[]) {
  if (resource.Type === "AWS::ApiGatewayV2::Route") {
    assert.equal(resource.Properties.AuthorizationType, "JWT");
    assert.match(resource.Properties.RouteKey, /\/v2\/alignments/);
  }
  if (resource.Type === "AWS::IAM::Policy") assert.doesNotMatch(JSON.stringify(resource), /secretsmanager:GetSecretValue/);
}
fs.rmSync(asset, { recursive: true });
console.log("cloud foundation and billing CDK assertions passed");
