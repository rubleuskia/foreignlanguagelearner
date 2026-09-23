import * as assert from "node:assert/strict";
import * as cdk from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { AlignmentStack } from "../lib/alignment-stack";

const app = new cdk.App({
  context: {
    workerRepositoryName: "alignment-worker",
    workerImageDigest: `sha256:${"a".repeat(64)}`,
    monthlyBudgetUsd: 50,
  },
});
const stack = new AlignmentStack(app, "Test", { env: { region: "eu-central-1" } });
const template = Template.fromStack(stack);

template.resourceCountIs("AWS::EC2::NatGateway", 0);
template.resourceCountIs("AWS::StepFunctions::StateMachineVersion", 1);
template.resourceCountIs("AWS::ApiGatewayV2::Route", 9);
template.hasResourceProperties("AWS::S3::Bucket", {
  VersioningConfiguration: { Status: "Enabled" },
  PublicAccessBlockConfiguration: {
    BlockPublicAcls: true,
    BlockPublicPolicy: true,
    IgnorePublicAcls: true,
    RestrictPublicBuckets: true,
  },
});
template.hasResourceProperties("AWS::ECS::TaskDefinition", {
  Cpu: "2048",
  Memory: "8192",
  RequiresCompatibilities: ["FARGATE"],
  RuntimePlatform: { CpuArchitecture: "X86_64", OperatingSystemFamily: "LINUX" },
});
const json = template.toJSON();
const stateMachine = Object.values(json.Resources).find((resource: any) =>
  resource.Type === "AWS::StepFunctions::StateMachine") as any;
const definition = JSON.stringify(stateMachine.Properties.DefinitionString);
assert.match(definition, /ecs:runTask\.sync/);
assert.match(definition, /TimeoutSeconds[^0-9]+13500/);
assert.match(definition, /AssignPublicIp[^A-Z]+ENABLED/);
assert.match(definition, /JobId/);
assert.equal(Object.values(json.Resources).some((resource: any) =>
  resource.Type === "AWS::EC2::SecurityGroupIngress"), false);
console.log("alignment CDK assertions passed");
