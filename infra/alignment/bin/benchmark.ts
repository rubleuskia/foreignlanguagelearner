#!/usr/bin/env node
// Disposable measurement infrastructure. No API or continuously running service.
import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";

const app = new cdk.App();
const project = app.node.tryGetContext("benchmarkProject") as string;
const digest = app.node.tryGetContext("workerImageDigest") as string;
const repository = app.node.tryGetContext("workerRepositoryName") as string;
const zone = app.node.tryGetContext("benchmarkZone") as string;
if (!/^\d{12}$/.test(project ?? "") || !/^sha256:[a-f0-9]{64}$/.test(digest ?? "") ||
    !/^[a-z0-9][a-z0-9._/-]+$/.test(repository ?? "") || !/^eu-north-1[a-z]$/.test(zone ?? "")) {
  throw new Error("Supply explicit benchmarkProject, workerRepositoryName, workerImageDigest and verified benchmarkZone");
}
app.node.setContext(`availability-zones:account=${project}:region=eu-north-1`, [zone]);
const stack = new cdk.Stack(app, "ForeignLanguageLearnerAudioBenchmark", {
  env: { account: project, region: "eu-north-1" },
  synthesizer: new cdk.BootstraplessSynthesizer(),
  description: "Disposable private Polish audio measurements; no API or ECS service. Export evidence before cleanup.",
});
stack.templateOptions.metadata = { AWSToolsMetrics: { AWSAgentToolkit: "aws-cloudformation@3" } };
cdk.Tags.of(stack).add("Purpose", "fll-audio-benchmark");
const bucket = new s3.Bucket(stack, "Evidence", { encryption: s3.BucketEncryption.S3_MANAGED,
  blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL, enforceSSL: true, versioned: true,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
  lifecycleRules: [{ expiration: cdk.Duration.days(1), noncurrentVersionExpiration: cdk.Duration.days(1) }] });
const vpc = new ec2.Vpc(stack, "Network", { availabilityZones: [zone], natGateways: 0,
  subnetConfiguration: [{ name: "Task", subnetType: ec2.SubnetType.PUBLIC }],
  gatewayEndpoints: { S3: { service: ec2.GatewayVpcEndpointAwsService.S3 } } });
const group = new ec2.SecurityGroup(stack, "TaskNetwork", { vpc, allowAllOutbound: false });
group.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443));
group.addEgressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.udp(53));
group.addEgressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(53));
const cluster = new ecs.Cluster(stack, "Cluster", { vpc });
const role = new iam.Role(stack, "MeasurementRole", { assumedBy: new iam.ServicePrincipal("ecs-tasks.amazonaws.com", {
  conditions: { StringEquals: { "aws:SourceAccount": project },
    ArnLike: { "aws:SourceArn": `arn:aws:ecs:eu-north-1:${project}:*` } },
}) });
bucket.grantRead(role, "input/*");
bucket.grantPut(role, "results/*");
const executionRole = new iam.Role(stack, "ExecutionRole", { assumedBy: new iam.ServicePrincipal("ecs-tasks.amazonaws.com", {
  conditions: { StringEquals: { "aws:SourceAccount": project },
    ArnLike: { "aws:SourceArn": `arn:aws:ecs:eu-north-1:${project}:*` } },
}) });
const task = new ecs.FargateTaskDefinition(stack, "Task", { cpu: 2048, memoryLimitMiB: 8192,
  taskRole: role, executionRole, runtimePlatform: { cpuArchitecture: ecs.CpuArchitecture.X86_64,
    operatingSystemFamily: ecs.OperatingSystemFamily.LINUX } });
const log = new logs.LogGroup(stack, "Logs", { retention: logs.RetentionDays.ONE_WEEK,
  removalPolicy: cdk.RemovalPolicy.DESTROY });
const boot = "import boto3,hashlib,os; from botocore.config import Config; s=boto3.client('s3',region_name='eu-north-1',config=Config(connect_timeout=5,read_timeout=30,retries={'total_max_attempts':2})); s.download_file(os.environ['BENCHMARK_BUCKET'],'input/driver.py','/tmp/driver.py'); d=open('/tmp/driver.py','rb').read(); assert hashlib.sha256(d).hexdigest()==os.environ['BENCHMARK_DRIVER_SHA256']; exec(compile(d,'/tmp/driver.py','exec'))";
task.addContainer("Measurement", {
  image: ecs.ContainerImage.fromEcrRepository(ecr.Repository.fromRepositoryName(stack, "Image", repository), digest),
  entryPoint: ["python", "-c"], command: [boot],
  environment: { BENCHMARK_BUCKET: bucket.bucketName, OPERATOR_ALIGNMENT_PILOT: "pl-300-v1",
    OMP_NUM_THREADS: "2", MKL_NUM_THREADS: "2" },
  logging: ecs.LogDrivers.awsLogs({ logGroup: log, streamPrefix: "safe-measurement" }),
});
for (const [name, value] of Object.entries({ Bucket: bucket.bucketName, Cluster: cluster.clusterArn,
  TaskDefinition: task.taskDefinitionArn, Subnet: vpc.publicSubnets[0].subnetId,
  SecurityGroup: group.securityGroupId, ImageDigest: digest })) {
  new cdk.CfnOutput(stack, `${name}Output`, { value }).overrideLogicalId(name);
}
for (const node of stack.node.findAll()) {
  if (node instanceof cdk.CfnResource) node.addMetadata("com.aws.cloudformation.Context", {
    why: "Disposable private benchmark infrastructure; export evidence before deleting the stack.",
    must: "Use eu-north-1, no public API or service, and retain project/application resources outside this stack.",
  });
}
