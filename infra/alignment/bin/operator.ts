#!/usr/bin/env node
import * as fs from "node:fs";
import * as path from "node:path";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { OperatorStack } from "../lib/operator-stack";
import { AlignmentStack } from "../lib/alignment-stack";
import { DEPLOYMENT_REGION } from "../lib/region";

const app = new cdk.App();
const asset = path.resolve(app.node.tryGetContext("cloudAsset") ?? "missing-operator-asset");
if (!fs.existsSync(path.join(asset, "backend/private_cloud/api.py"))) throw new Error("Build an operator cloudAsset first");
const code = () => lambda.Code.fromAsset(asset);
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: DEPLOYMENT_REGION };
const zones = String(app.node.tryGetContext("workerAvailabilityZones") ?? "").split(",");
if (app.node.tryGetContext("operatorAlignment") !== "false") {
  if (zones.length !== 2 || zones.some(zone => !/^eu-north-1[a-z]$/.test(zone)) || zones[0] === zones[1]) {
    throw new Error("Supply two verified Stockholm workerAvailabilityZones for lookup-free preparation");
  }
  app.node.setContext(`availability-zones:account=${env.account}:region=${DEPLOYMENT_REGION}`, zones);
}
const foundation = new OperatorStack(app, "ForeignLanguageLearnerOperator-prod", {
  env, code: code(), operatorUsername: app.node.tryGetContext("operatorUsername") ?? "operator",
  dailyModelLimit: Number(app.node.tryGetContext("dailyModelLimit") ?? "50"),
  openaiSecretArn: app.node.tryGetContext("openaiSecretArn") ?? "",
  alignmentEnabled: app.node.tryGetContext("operatorAlignment") !== "false",
});
if (app.node.tryGetContext("operatorAlignment") !== "false") {
  new AlignmentStack(app, "ForeignLanguageLearnerOperatorAlignment-prod", {
    env, cloudCode: code(), operatorFoundation: foundation,
    workerAvailabilityZones: zones,
    benchmarkReport: JSON.parse(fs.readFileSync(path.resolve(app.node.tryGetContext("alignmentBenchmarkReport") ?? "missing-benchmark-report"), "utf8")),
  });
}
