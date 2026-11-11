import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { Template } from "aws-cdk-lib/assertions";
import { OperatorStack, OPERATOR_MODEL } from "../lib/operator-stack";
import { AlignmentStack } from "../lib/alignment-stack";

const area = fs.mkdtempSync(path.join(os.tmpdir(), "fll-operator-"));
fs.writeFileSync(path.join(area, "index.py"), "# Test asset\n");
try {
  const digest = `sha256:${"a".repeat(64)}`;
  const app = new cdk.App({ context: { workerRepositoryName: "worker", workerImageDigest: digest } });
  const env = { account: "123456789012", region: "eu-north-1" };
  app.node.setContext("availability-zones:account=123456789012:region=eu-north-1", ["eu-north-1a", "eu-north-1b"]);
  const operator = new OperatorStack(app, "Operator", { env, code: lambda.Code.fromAsset(area),
    operatorUsername: "operator", dailyModelLimit: 50 });
  const report = { workerImageDigest: digest, scope: "operator-pl-300-v1", maxAudioSeconds: 300, maxJobCostUsd: 1,
    languages: Object.fromEntries(["pl"].map(language =>
      [language, { qualityAccepted: true, audioSeconds: 300, runs: 3, runtimeSeconds: 300, peakMemoryMiB: 1024, costUsd: 0.1 }])) };
  const alignment = new AlignmentStack(app, "OperatorAlignment", { env, operatorFoundation: operator,
    workerAvailabilityZones: ["eu-north-1a", "eu-north-1b"],
    cloudCode: lambda.Code.fromAsset(area), benchmarkReport: report });
  const foundation = Template.fromStack(operator), audio = Template.fromStack(alignment);
  foundation.resourceCountIs("AWS::Cognito::UserPoolIdentityProvider", 0);
  foundation.resourceCountIs("AWS::SQS::Queue", 0);
  foundation.resourceCountIs("AWS::DynamoDB::Table", 1);
  foundation.hasResourceProperties("AWS::Cognito::UserPool", {
    AdminCreateUserConfig: { AllowAdminCreateUserOnly: true },
    Policies: { PasswordPolicy: { MinimumLength: 14 } },
  });
  foundation.hasResourceProperties("AWS::Cognito::UserPoolClient", { GenerateSecret: false,
    ExplicitAuthFlows: ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"] });
  for (const resource of Object.values(foundation.findResources("AWS::Cognito::UserPoolClient"))) {
    assert.equal(resource.Properties.AllowedOAuthFlows, undefined);
    assert.equal(resource.Properties.CallbackURLs, undefined);
  }
  foundation.hasResourceProperties("AWS::Lambda::Function", { Handler: "backend.private_cloud.api.handler",
    Timeout: 28, ReservedConcurrentExecutions: 2 });
  for (const template of [foundation, audio]) {
    for (const route of Object.values(template.findResources("AWS::ApiGatewayV2::Route"))) {
      assert.equal(route.Properties.AuthorizationType, "JWT");
      assert.deepEqual(route.Properties.AuthorizationScopes, ["aws.cognito.signin.user.admin"]);
    }
    assert.equal(Object.values(template.findResources("AWS::EC2::NatGateway")).length, 0);
    assert.doesNotMatch(JSON.stringify(template.toJSON()), /secretsmanager:GetSecretValue|APPLE_API_SECRET_ARN|OPENAI_SECRET_ARN/);
  }
  foundation.resourceCountIs("AWS::ApiGatewayV2::Route", 8);
  audio.resourceCountIs("AWS::ApiGatewayV2::Route", 9);
  assert.match(JSON.stringify(foundation.toJSON()), /bedrock:InvokeModel/);
  assert.match(JSON.stringify(foundation.toJSON()), new RegExp(OPERATOR_MODEL.replaceAll(".", "\\.")));
  assert.doesNotMatch(JSON.stringify(foundation.toJSON()), /bedrock:\*/);
  audio.hasResourceProperties("AWS::Lambda::Function", { Handler: "backend.private_cloud.alignment.handler" });
  audio.hasResourceProperties("AWS::Lambda::Function", {
    Handler: "backend.private_cloud.alignment.handler",
    Environment: { Variables: { OPERATOR_ALIGNMENT_PILOT: "pl-300-v1" } },
  });
  for (const task of Object.values(audio.findResources("AWS::ECS::TaskDefinition"))) {
    assert.ok(task.Properties.ContainerDefinitions[0].Environment.some(
      (v: { Name: string; Value: string }) => v.Name === "OPERATOR_ALIGNMENT_PILOT" && v.Value === "pl-300-v1"));
  }
  assert.deepEqual(app.synth().manifest.missing ?? [], []);
  const badApp = new cdk.App({ context: { workerRepositoryName: "worker", workerImageDigest: digest } });
  const badOperator = new OperatorStack(badApp, "BadOperator", { env, code: lambda.Code.fromAsset(area),
    operatorUsername: "operator", dailyModelLimit: 50 });
  assert.throws(() => new AlignmentStack(badApp, "BadAlignment", { env, operatorFoundation: badOperator,
    cloudCode: lambda.Code.fromAsset(area), benchmarkReport: { ...report, workerImageDigest: "wrong" } }), /benchmark/);
  console.log("operator API, regional Bedrock and authenticated alignment CDK assertions passed");
} finally {
  fs.rmSync(area, { recursive: true, force: true });
}
