#!/usr/bin/env node
import * as path from "node:path";
import * as fs from "node:fs";
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { CloudTranslationStack } from "../lib/translation-stack";
import { AlignmentStack } from "../lib/alignment-stack";
import { CloudFoundationStack, CloudBillingStack } from "../lib/cloud-stack";
import { DEPLOYMENT_REGION } from "../lib/region";

const app = new cdk.App();
const required = (name: string): string => {
  const value = app.node.tryGetContext(name);
  if (typeof value !== "string" || !value.trim()) throw new Error(`Supply -c ${name}=...`);
  return value;
};
const requiredSecret = (name: string): string => {
  const arn = required(name);
  if (!arn.startsWith(`arn:aws:secretsmanager:${DEPLOYMENT_REGION}:`)) {
    throw new Error(`${name} must reference a Secrets Manager secret in ${DEPLOYMENT_REGION}`);
  }
  return arn;
};
const stage = required("stage");
if (stage !== "dev" && stage !== "prod") throw new Error("stage must be dev or prod");
const asset = path.resolve(required("cloudAsset"));
for (const file of ["backend/billing/api.py", "appstoreserverlibrary/__init__.py", "apple-roots"]) {
  if (!fs.existsSync(path.join(asset, file))) throw new Error(`Incomplete Linux cloud artifact: ${file}`);
}
const policyPath = app.node.tryGetContext("cloudPolicy");
const cloudPolicy = policyPath ? JSON.stringify(JSON.parse(fs.readFileSync(path.resolve(policyPath), "utf8"))) : undefined;
if (cloudPolicy && Buffer.byteLength(cloudPolicy) > 1024) throw new Error("Cloud policy must fit within 1024 bytes of Lambda environment budget");
if (cloudPolicy) JSON.parse(cloudPolicy);
const paidAlignment = app.node.tryGetContext("paidAlignment") === "true";
const translations = app.node.tryGetContext("acceptTranslations") === "true";
if (translations && !cloudPolicy) throw new Error("Enabling translations requires an explicit product policy file");
const products = required("appleProducts").split(",").map(product => product.trim());
if (cloudPolicy && Object.keys(JSON.parse(cloudPolicy).products ?? {}).some(product => !products.includes(product))) throw new Error("Cloud policy contains an unapproved Apple product");
const code = () => lambda.Code.fromAsset(asset);
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: DEPLOYMENT_REGION };
const foundation = new CloudFoundationStack(app, `ForeignLanguageLearnerCloudFoundation-${stage}`, {
  env, stage, code: code(), cloudPolicy, appleProducts: products, acceptTranslations: translations, acceptAlignments: paidAlignment,
  appleClientId: required("appleClientId"), appleTeamId: required("appleTeamId"),
  appleKeyId: required("appleSignInKeyId"), appleSignInSecretArn: requiredSecret("appleSignInSecretArn"),
  callbackUrl: required("callbackUrl"), domainPrefix: required("loginDomainPrefix"),
});
new CloudBillingStack(app, `ForeignLanguageLearnerCloudBilling-${stage}`, {
  env, foundation, code: code(), appleApiSecretArn: requiredSecret("appleApiSecretArn"),
  bundleId: "com.rubleuskia.foreignlanguagelearner", appAppleId: app.node.tryGetContext("appAppleId"),
  products,
});

if (app.node.tryGetContext("cloudComponents") !== "billing") {
  new CloudTranslationStack(app, `ForeignLanguageLearnerCloudTranslation-${stage}`, {
    env, foundation, code: code(), openaiSecretArn: requiredSecret("openaiSecretArn"),
  });
} else if (translations) throw new Error("Billing-only assembly cannot enable translations");
if (paidAlignment) {
  if (!cloudPolicy) throw new Error("Paid alignment requires an explicit product policy");
  const benchmarkReport = JSON.parse(fs.readFileSync(path.resolve(required("alignmentBenchmarkReport")), "utf8"));
  new AlignmentStack(app, `ForeignLanguageLearnerPaidAlignment-${stage}`, {
    env, paidFoundation: foundation, cloudCode: code(), benchmarkReport,
  });
}
