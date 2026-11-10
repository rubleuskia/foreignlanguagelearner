import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { Template } from "aws-cdk-lib/assertions";

const directory = fs.mkdtempSync(path.join(os.tmpdir(), "fll-benchmark-plan-"));
try {
  const result = spawnSync(process.execPath, ["-r", "ts-node/register", "bin/benchmark.ts"], {
    env: { ...process.env, CDK_OUTDIR: directory, CDK_CONTEXT_JSON: JSON.stringify({
      benchmarkProject: "123456789012", benchmarkZone: "eu-north-1a",
      workerRepositoryName: "worker", workerImageDigest: `sha256:${"a".repeat(64)}`,
    }) }, encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  const data = JSON.parse(fs.readFileSync(path.join(directory, "ForeignLanguageLearnerAudioBenchmark.template.json"), "utf8"));
  const template = Template.fromJSON(data);
  for (const type of ["AWS::ApiGatewayV2::Api", "AWS::ECS::Service", "AWS::EC2::NatGateway", "AWS::Lambda::Function"])
    template.resourceCountIs(type, 0);
  template.resourceCountIs("AWS::ECS::TaskDefinition", 1);
  template.resourceCountIs("AWS::IAM::Role", 2);
  template.hasResourceProperties("AWS::ECS::TaskDefinition", { Cpu: "2048", Memory: "8192",
    RuntimePlatform: { CpuArchitecture: "X86_64", OperatingSystemFamily: "LINUX" } });
  template.hasResourceProperties("AWS::S3::Bucket", { PublicAccessBlockConfiguration: {
    BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true } });
  assert.equal(data.Parameters?.BootstrapVersion, undefined);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, "manifest.json"), "utf8")).missing ?? [], []);
  console.log("private disposable benchmark plan assertions passed");
} finally { fs.rmSync(directory, { recursive: true, force: true }); }
