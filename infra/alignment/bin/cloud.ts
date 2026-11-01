#!/usr/bin/env node
import * as path from "node:path";
import * as fs from "node:fs";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { CloudFoundationStack, CloudBillingStack } from "../lib/cloud-stack";

const app = new cdk.App();
const required = (name: string): string => {
  const value = app.node.tryGetContext(name);
  if (typeof value !== "string" || !value.trim()) throw new Error(`Supply -c ${name}=...`);
  return value;
};
const stage = required("stage");
if (stage !== "dev" && stage !== "prod") throw new Error("stage must be dev or prod");
const asset = path.resolve(required("cloudAsset"));
for (const file of ["backend/billing/api.py", "appstoreserverlibrary/__init__.py", "apple-roots"]) {
  if (!fs.existsSync(path.join(asset, file))) throw new Error(`Incomplete Linux cloud artifact: ${file}`);
}
const code = () => lambda.Code.fromAsset(asset);
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: "eu-central-1" };
const foundation = new CloudFoundationStack(app, `ForeignLanguageLearnerCloudFoundation-${stage}`, {
  env, stage, code: code(),
  appleClientId: required("appleClientId"), appleTeamId: required("appleTeamId"),
  appleKeyId: required("appleSignInKeyId"), appleSignInSecretArn: required("appleSignInSecretArn"),
  callbackUrl: required("callbackUrl"), domainPrefix: required("loginDomainPrefix"),
});
new CloudBillingStack(app, `ForeignLanguageLearnerCloudBilling-${stage}`, {
  env, foundation, code: code(), appleApiSecretArn: required("appleApiSecretArn"),
  bundleId: "com.rubleuskia.foreignlanguagelearner", appAppleId: app.node.tryGetContext("appAppleId"),
  products: required("appleProducts").split(",").map(product => product.trim()),
});
