import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { Template } from "aws-cdk-lib/assertions";
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
  // Synthesize the entire assembly to detect cross-stack dependency cycles too.
  app.synth();
  const base = Template.fromStack(foundation);
  const bill = Template.fromStack(billing);
  base.resourceCountIs("AWS::Cognito::UserPool", 1);
  base.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 1);
  base.resourceCountIs("AWS::DynamoDB::Table", 2);
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
        assert.equal(resource.Properties.TimeToLiveSpecification, undefined);
        assert.equal(resource.Properties.PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled, true);
      }
      if (resource.Type === "AWS::ApiGatewayV2::Route") {
        const publicWebhook = resource.Properties.RouteKey === "POST /v1/webhooks/apple";
        assert.equal(resource.Properties.AuthorizationType, publicWebhook ? "NONE" : "JWT");
        if (!publicWebhook) assert.deepEqual(resource.Properties.AuthorizationScopes, ["paid-cloud/access"]);
      }
    }
  }
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
fs.rmSync(asset, { recursive: true });
console.log("cloud foundation and billing CDK assertions passed");
