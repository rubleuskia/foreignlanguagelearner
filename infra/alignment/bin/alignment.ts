#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { AlignmentStack } from "../lib/alignment-stack";
import { DEPLOYMENT_REGION } from "../lib/region";

const app = new cdk.App();
const targetRegion = app.node.tryGetContext("region") ?? process.env.CDK_DEFAULT_REGION ?? DEPLOYMENT_REGION;
new AlignmentStack(app, "ForeignLanguageLearnerAlignmentDev", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: targetRegion,
  },
  description: "Public-test, capability-authorized audio/TXT alignment backend",
});
