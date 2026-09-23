import * as path from "node:path";
import * as cdk from "aws-cdk-lib";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as budgets from "aws-cdk-lib/aws-budgets";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as sfn from "aws-cdk-lib/aws-stepfunctions";
import * as tasks from "aws-cdk-lib/aws-stepfunctions-tasks";
import { Construct } from "constructs";

export class AlignmentStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    if (props?.env?.region && props.env.region !== "eu-central-1") {
      throw new Error("Alignment public test must be synthesized for eu-central-1");
    }
    const workerRepositoryName = this.node.tryGetContext("workerRepositoryName") as string | undefined;
    const workerImageDigest = this.node.tryGetContext("workerImageDigest") as string | undefined;
    if (!workerRepositoryName || !workerImageDigest?.match(/^sha256:[0-9a-f]{64}$/)) {
      throw new Error("Supply -c workerRepositoryName=<ECR repository> -c workerImageDigest=sha256:<digest>");
    }

    const bucket = new s3.Bucket(this, "TemporaryBucket", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [{
        id: "OrphanFallback",
        enabled: true,
        expiration: cdk.Duration.days(3),
        noncurrentVersionExpiration: cdk.Duration.days(3),
        abortIncompleteMultipartUploadAfter: cdk.Duration.days(3),
      }, {
        id: "ExpiredDeleteMarkers",
        enabled: true,
        expiredObjectDeleteMarker: true,
      }],
    });
    const table = new dynamodb.Table(this, "JobsTable", {
      partitionKey: { name: "pk", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "sk", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: "delete_after",
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const vpc = new ec2.Vpc(this, "WorkerVpc", {
      natGateways: 0,
      maxAzs: 2,
      subnetConfiguration: [{ name: "Public", subnetType: ec2.SubnetType.PUBLIC }],
      gatewayEndpoints: {
        S3: { service: ec2.GatewayVpcEndpointAwsService.S3 },
      },
    });
    const cluster = new ecs.Cluster(this, "WorkerCluster", { vpc });
    const securityGroup = new ec2.SecurityGroup(this, "WorkerSecurityGroup", {
      vpc,
      allowAllOutbound: false,
      description: "No inbound listeners; outbound DNS/HTTPS for AWS APIs and image pulls",
    });
    securityGroup.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), "HTTPS to AWS public APIs");
    securityGroup.addEgressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.udp(53), "VPC DNS UDP");
    securityGroup.addEgressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(53), "VPC DNS TCP");

    const executionRole = new iam.Role(this, "WorkerExecutionRole", {
      assumedBy: new iam.ServicePrincipal("ecs-tasks.amazonaws.com"),
    });
    executionRole.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName(
      "service-role/AmazonECSTaskExecutionRolePolicy",
    ));
    const taskRole = new iam.Role(this, "WorkerTaskRole", {
      assumedBy: new iam.ServicePrincipal("ecs-tasks.amazonaws.com"),
    });
    bucket.grantReadWrite(taskRole);
    table.grantReadWriteData(taskRole);
    const logGroup = new logs.LogGroup(this, "WorkerLogs", {
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const taskDefinition = new ecs.FargateTaskDefinition(this, "WorkerTask", {
      cpu: 2048,
      memoryLimitMiB: 8192,
      runtimePlatform: {
        cpuArchitecture: ecs.CpuArchitecture.X86_64,
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
      },
      executionRole,
      taskRole,
    });
    cdk.Tags.of(taskDefinition).add("Backend", "alignment-v1");
    const workerRepository = ecr.Repository.fromRepositoryName(this, "WorkerRepository", workerRepositoryName);
    const container = taskDefinition.addContainer("Worker", {
      image: ecs.ContainerImage.fromEcrRepository(workerRepository, workerImageDigest),
      environment: {
        ALIGNMENT_TABLE: table.tableName,
        ALIGNMENT_BUCKET: bucket.bucketName,
        MODEL_DIR: "/opt/models",
        WORKER_IMAGE_DIGEST: workerImageDigest,
      },
      logging: ecs.LogDrivers.awsLogs({ logGroup, streamPrefix: "safe-worker-events" }),
      stopTimeout: cdk.Duration.seconds(120),
    });

    const lambdaCode = lambda.Code.fromAsset(path.join(__dirname, "../../../backend"), {
      exclude: ["**/__pycache__/**", "**/test_*.py"],
    });
    const commonEnvironment = {
      ALIGNMENT_TABLE: table.tableName,
      ALIGNMENT_BUCKET: bucket.bucketName,
      ECS_CLUSTER_ARN: cluster.clusterArn,
      BACKEND_TAG: "alignment-v1",
      ACCEPT_NEW_JOBS: "true",
    };
    const finalizer = new lambda.Function(this, "Finalizer", {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "alignment.finalizer.handler",
      code: lambdaCode,
      timeout: cdk.Duration.seconds(30),
      memorySize: 512,
      environment: { ...commonEnvironment, STATE_MACHINE_ARN: "PENDING" },
    });
    bucket.grantReadWrite(finalizer);
    table.grantReadWriteData(finalizer);

    const prepare = new sfn.Pass(this, "CanonicalWorkerInput", {
      parameters: {
        "job_id.$": "$.job_id",
        "input_json.$": "States.JsonToString($)",
      },
    });
    const publicSubnetIds = vpc.selectSubnets({ subnetType: ec2.SubnetType.PUBLIC }).subnetIds;
    const runTask = new sfn.CustomState(this, "RunWorkerOnce", {
      stateJson: {
        Type: "Task",
        Resource: "arn:aws:states:::ecs:runTask.sync",
        Parameters: {
          Cluster: cluster.clusterArn,
          TaskDefinition: taskDefinition.taskDefinitionArn,
          LaunchType: "FARGATE",
          PlatformVersion: "LATEST",
          NetworkConfiguration: {
            AwsvpcConfiguration: {
              Subnets: publicSubnetIds,
              SecurityGroups: [securityGroup.securityGroupId],
              AssignPublicIp: "ENABLED",
            },
          },
          Overrides: {
            ContainerOverrides: [{
              Name: container.containerName,
              Environment: [{ Name: "ALIGNMENT_INPUT", "Value.$": "$.input_json" }],
            }],
          },
          PropagateTags: "TASK_DEFINITION",
          Tags: [
            { Key: "Backend", Value: "alignment-v1" },
            { Key: "JobId", "Value.$": "$.job_id" },
          ],
        },
        ResultPath: "$.task",
        TimeoutSeconds: 13500,
        HeartbeatSeconds: 600,
      },
    });
    const finalizeSuccess = new tasks.LambdaInvoke(this, "Finalize", {
      lambdaFunction: finalizer,
      payload: sfn.TaskInput.fromObject({
        "job_id.$": "$.job_id",
        "task.$": "$.task",
      }),
      payloadResponseOnly: true,
    });
    const safeFailure = new sfn.Pass(this, "RemoveUnsafeFailureCause", {
      parameters: { "job_id.$": "$.job_id", safe_failure: "TaskFailure" },
    });
    const timeoutFailure = new sfn.Pass(this, "RemoveUnsafeTimeoutCause", {
      parameters: { "job_id.$": "$.job_id", safe_failure: "States.Timeout" },
    });
    const finalizeFailure = new tasks.LambdaInvoke(this, "FinalizeFailure", {
      lambdaFunction: finalizer,
      payloadResponseOnly: true,
    });
    const finalizeTimeout = new tasks.LambdaInvoke(this, "FinalizeTimeout", {
      lambdaFunction: finalizer,
      payloadResponseOnly: true,
    });
    safeFailure.next(finalizeFailure);
    timeoutFailure.next(finalizeTimeout);
    runTask.addCatch(timeoutFailure, { errors: ["States.Timeout"], resultPath: sfn.JsonPath.DISCARD });
    runTask.addCatch(safeFailure, { errors: ["States.ALL"], resultPath: sfn.JsonPath.DISCARD });
    const stateMachine = new sfn.StateMachine(this, "StateMachine", {
      definitionBody: sfn.DefinitionBody.fromChainable(prepare.next(runTask).next(finalizeSuccess)),
      timeout: cdk.Duration.hours(4),
      tracingEnabled: true,
      logs: {
        destination: new logs.LogGroup(this, "WorkflowLogs", {
          retention: logs.RetentionDays.ONE_WEEK,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
        level: sfn.LogLevel.ERROR,
        includeExecutionData: false,
      },
    });
    cdk.Tags.of(stateMachine).add("Backend", "alignment-v1");
    stateMachine.addToRolePolicy(new iam.PolicyStatement({
      actions: ["ecs:RunTask"],
      resources: [taskDefinition.taskDefinitionArn],
    }));
    stateMachine.addToRolePolicy(new iam.PolicyStatement({
      actions: ["ecs:StopTask", "ecs:DescribeTasks"],
      resources: ["*"],
      conditions: { StringEquals: { "aws:ResourceTag/Backend": "alignment-v1" } },
    }));
    stateMachine.addToRolePolicy(new iam.PolicyStatement({
      actions: ["iam:PassRole"],
      resources: [taskRole.roleArn, executionRole.roleArn],
    }));
    stateMachine.addToRolePolicy(new iam.PolicyStatement({
      actions: ["events:PutTargets", "events:PutRule", "events:DescribeRule"],
      resources: [`arn:${this.partition}:events:${this.region}:${this.account}:rule/StepFunctionsGetEventsForECSTaskRule`],
    }));
    const version = new sfn.CfnStateMachineVersion(this, "StateMachineVersion", {
      stateMachineArn: stateMachine.stateMachineArn,
      description: `Worker image ${workerImageDigest}`,
    });

    const apiHandler = new lambda.Function(this, "ApiHandler", {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "alignment.api.handler",
      code: lambdaCode,
      timeout: cdk.Duration.seconds(30),
      memorySize: 512,
      environment: { ...commonEnvironment, STATE_MACHINE_ARN: version.attrArn },
    });
    bucket.grantReadWrite(apiHandler);
    table.grantReadWriteData(apiHandler);
    apiHandler.addToRolePolicy(new iam.PolicyStatement({
      actions: ["states:StartExecution"],
      resources: [version.attrArn],
    }));
    stateMachine.grantRead(apiHandler);
    apiHandler.addToRolePolicy(new iam.PolicyStatement({
      actions: ["states:StopExecution"],
      resources: [`arn:${this.partition}:states:${this.region}:${this.account}:execution:${stateMachine.stateMachineName}:*`],
    }));
    apiHandler.addToRolePolicy(new iam.PolicyStatement({
      actions: ["ecs:StopTask"],
      resources: ["*"],
      conditions: { StringEquals: { "aws:ResourceTag/Backend": "alignment-v1" } },
    }));

    const httpApi = new apigwv2.HttpApi(this, "HttpApi", {
      createDefaultStage: true,
      corsPreflight: undefined,
    });
    const defaultStage = httpApi.defaultStage?.node.defaultChild as apigwv2.CfnStage;
    defaultStage.defaultRouteSettings = { throttlingBurstLimit: 20, throttlingRateLimit: 10 };
    const integration = new integrations.HttpLambdaIntegration("ApiIntegration", apiHandler);
    const routes: [apigwv2.HttpMethod, string][] = [
      [apigwv2.HttpMethod.POST, "/v1/alignments"],
      [apigwv2.HttpMethod.GET, "/v1/alignments/{id}"],
      [apigwv2.HttpMethod.GET, "/v1/alignments/{id}/upload"],
      [apigwv2.HttpMethod.POST, "/v1/alignments/{id}/upload-urls"],
      [apigwv2.HttpMethod.POST, "/v1/alignments/{id}/complete-upload"],
      [apigwv2.HttpMethod.POST, "/v1/alignments/{id}/start"],
      [apigwv2.HttpMethod.GET, "/v1/alignments/{id}/result"],
      [apigwv2.HttpMethod.GET, "/v1/alignments/{id}/diagnostics"],
      [apigwv2.HttpMethod.POST, "/v1/alignments/{id}/cancel"],
    ];
    for (const [method, routePath] of routes) {
      httpApi.addRoutes({ path: routePath, methods: [method], integration });
    }

    const reconciler = new lambda.Function(this, "Reconciler", {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "alignment.reconciler.handler",
      code: lambdaCode,
      timeout: cdk.Duration.minutes(2),
      memorySize: 512,
      environment: { ...commonEnvironment, STATE_MACHINE_ARN: version.attrArn },
    });
    bucket.grantReadWrite(reconciler);
    table.grantReadWriteData(reconciler);
    reconciler.addToRolePolicy(new iam.PolicyStatement({
      actions: ["states:StartExecution"], resources: [version.attrArn],
    }));
    reconciler.addToRolePolicy(new iam.PolicyStatement({
      actions: ["states:StopExecution", "ecs:StopTask", "ecs:ListTasks", "ecs:ListTagsForResource"],
      resources: ["*"],
    }));
    new events.Rule(this, "ReconcileSchedule", {
      schedule: events.Schedule.rate(cdk.Duration.minutes(5)),
      targets: [new targets.LambdaFunction(reconciler)],
    });

    for (const [name, fn] of [["Api", apiHandler], ["Finalizer", finalizer], ["Reconciler", reconciler]] as const) {
      new cloudwatch.Alarm(this, `${name}Errors`, {
        metric: fn.metricErrors({ period: cdk.Duration.minutes(5) }),
        threshold: 1,
        evaluationPeriods: 1,
      });
    }
    new budgets.CfnBudget(this, "DevelopmentBudget", {
      budget: {
        budgetName: "foreign-language-learner-alignment-dev",
        budgetType: "COST",
        timeUnit: "MONTHLY",
        budgetLimit: { amount: Number(this.node.tryGetContext("monthlyBudgetUsd") ?? 50), unit: "USD" },
      },
    });

    new cdk.CfnOutput(this, "ApiUrl", { value: httpApi.url ?? "" });
    new cdk.CfnOutput(this, "BucketName", { value: bucket.bucketName });
    new cdk.CfnOutput(this, "TableName", { value: table.tableName });
  }
}
