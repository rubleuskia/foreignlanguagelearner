import * as cdk from "aws-cdk-lib";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as db from "aws-cdk-lib/aws-dynamodb";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as sources from "aws-cdk-lib/aws-lambda-event-sources";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as logs from "aws-cdk-lib/aws-logs";
import { Construct } from "constructs";
import { OperatorStack } from "./operator-stack";

/** Queue-only whole-book path. Legacy pilot resources remain retained during migration. */
export class BookAlignment extends Construct {
  constructor(scope: Construct, id: string, props: {
    operator: OperatorStack; code: lambda.Code; cluster: ecs.Cluster; securityGroup: ec2.SecurityGroup;
    repository: ecr.IRepository; digest: string; maxWorkers?: number;
  }) {
    super(scope, id);
    const bucket = new s3.Bucket(this, "Artifacts", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL, enforceSSL: true, versioned: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED, encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [{ expiration: cdk.Duration.days(30), noncurrentVersionExpiration: cdk.Duration.days(30),
        abortIncompleteMultipartUploadAfter: cdk.Duration.days(1) }],
    });
    const table = new db.Table(this, "Requests", {
      partitionKey: { name: "owner", type: db.AttributeType.STRING },
      sortKey: { name: "job_id", type: db.AttributeType.STRING },
      billingMode: db.BillingMode.PAY_PER_REQUEST, deletionProtection: true,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN, stream: db.StreamViewType.NEW_AND_OLD_IMAGES,
    });
    table.addGlobalSecondaryIndex({ indexName: "Recovery",
      partitionKey: { name: "dispatch_state", type: db.AttributeType.STRING },
      sortKey: { name: "ready_at", type: db.AttributeType.NUMBER }, projectionType: db.ProjectionType.ALL });
    const dead = new sqs.Queue(this, "DeadLetters", { encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true, retentionPeriod: cdk.Duration.days(14) });
    const queue = new sqs.Queue(this, "Queue", { encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true, retentionPeriod: cdk.Duration.days(14), visibilityTimeout: cdk.Duration.minutes(2),
      deadLetterQueue: { queue: dead, maxReceiveCount: 5 } });
    const environment = { ...props.operator.common, BOOK_ALIGNMENT_TABLE: table.tableName,
      BOOK_ALIGNMENT_BUCKET: bucket.bucketName, BOOK_ALIGNMENT_QUEUE: queue.queueUrl };
    const api = new lambda.Function(this, "Api", {
      runtime: lambda.Runtime.PYTHON_3_12, code: props.code, handler: "backend.book_alignment.api.handler",
      environment, timeout: cdk.Duration.seconds(28), memorySize: 256,
      logGroup: new logs.LogGroup(this, "ApiLogs", { retention: logs.RetentionDays.ONE_WEEK }),
    });
    table.grantReadWriteData(api); props.operator.table.grantReadWriteData(api);
    bucket.grantRead(api, "books/*"); bucket.grantPut(api, "books/*");
    const dispatcher = new lambda.Function(this, "Dispatcher", {
      runtime: lambda.Runtime.PYTHON_3_12, code: props.code, handler: "backend.book_alignment.dispatch.handler",
      environment, timeout: cdk.Duration.seconds(60), memorySize: 256,
      logGroup: new logs.LogGroup(this, "DispatchLogs", { retention: logs.RetentionDays.ONE_WEEK }),
    });
    queue.grantSendMessages(dispatcher); table.grantReadData(dispatcher);
    dispatcher.addEventSource(new sources.DynamoEventSource(table, { startingPosition: lambda.StartingPosition.TRIM_HORIZON,
      batchSize: 20, bisectBatchOnError: true, reportBatchItemFailures: true,
      retryAttempts: 10, onFailure: new sources.SqsDlq(dead) }));
    new events.Rule(this, "RecoverySchedule", { schedule: events.Schedule.rate(cdk.Duration.minutes(1)),
      targets: [new targets.LambdaFunction(dispatcher)] });
    const task = new ecs.FargateTaskDefinition(this, "WorkerTask", { cpu: 2048, memoryLimitMiB: 8192,
      ephemeralStorageGiB: 40, runtimePlatform: { cpuArchitecture: ecs.CpuArchitecture.X86_64,
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX } });
    task.addContainer("Worker", { image: ecs.ContainerImage.fromEcrRepository(props.repository, props.digest),
      environment: { BOOK_ALIGNMENT_TABLE: table.tableName, BOOK_ALIGNMENT_BUCKET: bucket.bucketName,
        BOOK_ALIGNMENT_QUEUE: queue.queueUrl, MODEL_DIR: "/opt/models" },
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: "book-worker",
        logGroup: new logs.LogGroup(this, "WorkerLogs", { retention: logs.RetentionDays.ONE_WEEK }) }),
      stopTimeout: cdk.Duration.seconds(120) });
    bucket.grantRead(task.taskRole, "books/*"); bucket.grantPut(task.taskRole, "books/*");
    table.grantReadWriteData(task.taskRole);
    queue.grantConsumeMessages(task.taskRole);
    const service = new ecs.FargateService(this, "Workers", { cluster: props.cluster, taskDefinition: task,
      desiredCount: 1, minHealthyPercent: 0, maxHealthyPercent: 100, assignPublicIp: true,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC }, securityGroups: [props.securityGroup],
      circuitBreaker: { rollback: true } });
    // One worker today. Scale-out can be enabled explicitly after capacity/quality measurement.
    const maxWorkers = props.maxWorkers ?? 1;
    const scaling = service.autoScaleTaskCount({ minCapacity: 1, maxCapacity: maxWorkers });
    scaling.scaleOnMetric("QueueScaleOut", { metric: queue.metricApproximateNumberOfMessagesVisible(),
      scalingSteps: [{ upper: 0, change: 0 }, { lower: 1, change: 1 }], cooldown: cdk.Duration.minutes(2),
      adjustmentType: cdk.aws_applicationautoscaling.AdjustmentType.CHANGE_IN_CAPACITY });
    const integration = new HttpLambdaIntegration("BookAlignment", api);
    const routes: [apigw.HttpMethod, string][] = [
      [apigw.HttpMethod.GET, "/v1/book-alignments"], [apigw.HttpMethod.POST, "/v1/book-alignments"],
      [apigw.HttpMethod.GET, "/v1/book-alignments/{id}"],
      [apigw.HttpMethod.POST, "/v1/book-alignments/{id}/upload"],
      [apigw.HttpMethod.POST, "/v1/book-alignments/{id}/complete"],
      [apigw.HttpMethod.POST, "/v1/book-alignments/{id}/start"],
      [apigw.HttpMethod.GET, "/v1/book-alignments/{id}/result"],
    ];
    for (const [method, path] of routes) {
      new apigw.HttpRoute(this, `${method}${path}`, { httpApi: props.operator.api,
        routeKey: apigw.HttpRouteKey.with(path, method), authorizer: props.operator.authorizer,
        authorizationScopes: ["aws.cognito.signin.user.admin"], integration });
    }
    for (const [name, metric, threshold] of [
      ["ApiErrors", api.metricErrors(), 1], ["DispatchErrors", dispatcher.metricErrors(), 1],
      ["DeadLettersPresent", dead.metricApproximateNumberOfMessagesVisible(), 1],
      ["QueueAge", queue.metricApproximateAgeOfOldestMessage(), 3600],
      ["TableThrottles", table.metricThrottledRequestsForOperations({ operations: [db.Operation.PUT_ITEM, db.Operation.GET_ITEM] }), 1],
    ] as const) {
      new cw.Alarm(this, name, { metric, threshold, evaluationPeriods: 1,
        treatMissingData: cw.TreatMissingData.NOT_BREACHING })
        .addAlarmAction(new actions.SnsAction(props.operator.alarms));
    }
    new cdk.CfnOutput(cdk.Stack.of(this), "BookAlignmentBucket", { value: bucket.bucketName });
    new cdk.CfnOutput(cdk.Stack.of(this), "BookAlignmentQueue", { value: queue.queueUrl });
  }
}
