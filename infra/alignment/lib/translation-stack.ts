import * as cdk from "aws-cdk-lib";
import * as db from "aws-cdk-lib/aws-dynamodb";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as sources from "aws-cdk-lib/aws-lambda-event-sources";
import * as destinations from "aws-cdk-lib/aws-lambda-destinations";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as iam from "aws-cdk-lib/aws-iam";
import * as secrets from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";
import { CloudFoundationStack } from "./cloud-stack";

interface TranslationProps extends cdk.StackProps {
  readonly foundation: CloudFoundationStack;
  readonly code: lambda.Code;
  readonly openaiSecretArn: string;
}

export class CloudTranslationStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: TranslationProps) {
    super(scope, id, props);
    const f = props.foundation;
    const requests = new db.Table(this, "Requests", {
      partitionKey: { name: "request_id", type: db.AttributeType.STRING },
      stream: db.StreamViewType.KEYS_ONLY, timeToLiveAttribute: "delete_after",
      billingMode: db.BillingMode.PAY_PER_REQUEST, encryption: db.TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true }, removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const contents = new db.Table(this, "TemporaryContents", {
      partitionKey: { name: "request_id", type: db.AttributeType.STRING },
      timeToLiveAttribute: "delete_after", billingMode: db.BillingMode.PAY_PER_REQUEST,
      encryption: db.TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: false }, removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    cdk.Tags.of(contents).add("DataClass", "temporary-content-no-backups");
    const dlq = new sqs.Queue(this, "DeadLetters", { retentionPeriod: cdk.Duration.days(14),
      encryption: sqs.QueueEncryption.SQS_MANAGED, enforceSSL: true });
    const queue = new sqs.Queue(this, "InferenceQueue", { visibilityTimeout: cdk.Duration.minutes(15),
      encryption: sqs.QueueEncryption.SQS_MANAGED, enforceSSL: true,
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 } });
    const maintenance = new sqs.Queue(this, "MaintenanceQueue", { visibilityTimeout: cdk.Duration.minutes(30),
      encryption: sqs.QueueEncryption.SQS_MANAGED, enforceSSL: true,
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 } });
    const common = { ...f.common, TRANSLATION_REQUESTS_TABLE: requests.tableName,
      TRANSLATION_CONTENTS_TABLE: contents.tableName };
    const fn = (name: string, handler: string, timeout: number, environment: Record<string, string> = {}) => new lambda.Function(this, name, {
      code: props.code, runtime: lambda.Runtime.PYTHON_3_12, handler,
      timeout: cdk.Duration.seconds(timeout), memorySize: 256, reservedConcurrentExecutions: 2,
      environment: { ...common, ...environment },
      logGroup: new logs.LogGroup(this, `${name}Logs`, { retention: logs.RetentionDays.ONE_WEEK }),
    });
    const api = fn("RequestApi", "backend.translation.api.handler", 15);
    api.addToRolePolicy(new iam.PolicyStatement({ actions: ["cognito-idp:AdminGetUser"], resources: [f.pool.userPoolArn] }));
    const dispatch = fn("Dispatch", "backend.translation.worker.dispatch_handler", 30, { TRANSLATION_QUEUE_URL: queue.queueUrl });
    const worker = fn("Inference", "backend.translation.worker.worker_handler", 90, { OPENAI_SECRET_ARN: props.openaiSecretArn });
    const sweep = fn("Maintenance", "backend.translation.worker.maintenance_handler", 300,
      { TRANSLATION_QUEUE_URL: queue.queueUrl, TRANSLATION_MAINTENANCE_URL: maintenance.queueUrl });
    for (const target of [api, worker, sweep]) {
      requests.grantReadWriteData(target); contents.grantReadWriteData(target); f.usage.grantReadWriteData(target);
      f.accounts.grantReadData(target); f.subscriptions.grantReadData(target);
    }
    secrets.Secret.fromSecretCompleteArn(this, "ProviderKey", props.openaiSecretArn).grantRead(worker);
    queue.grantSendMessages(dispatch); queue.grantSendMessages(sweep); maintenance.grantSendMessages(sweep);
    dispatch.addEventSource(new sources.DynamoEventSource(requests, { startingPosition: lambda.StartingPosition.TRIM_HORIZON,
      batchSize: 10, reportBatchItemFailures: true, retryAttempts: 5,
      maxRecordAge: cdk.Duration.hours(6), onFailure: new sources.SqsDlq(dlq) }));
    worker.addEventSource(new sources.SqsEventSource(queue, { batchSize: 1, maxConcurrency: 2, reportBatchItemFailures: true }));
    sweep.addEventSource(new sources.SqsEventSource(maintenance, { batchSize: 1, maxConcurrency: 2, reportBatchItemFailures: true }));
    new events.Rule(this, "MaintenanceSchedule", { schedule: events.Schedule.rate(cdk.Duration.minutes(5)),
      targets: [new targets.LambdaFunction(sweep, { deadLetterQueue: dlq, retryAttempts: 2 })] });
    sweep.configureAsyncInvoke({ onFailure: new destinations.SqsDestination(dlq), retryAttempts: 2 });
    for (const [method, path] of [[apigw.HttpMethod.POST, "/v1/context-analyses"],
      [apigw.HttpMethod.POST, "/v1/word-explanations"], [apigw.HttpMethod.GET, "/v1/requests/{id}"],
      [apigw.HttpMethod.POST, "/v1/requests/{id}/cancel"], [apigw.HttpMethod.GET, "/v1/requests/by-key/{key}"]] as const) {
      new apigw.HttpRoute(this, `${method}${path}`, { httpApi: f.api, routeKey: apigw.HttpRouteKey.with(path, method),
        authorizer: f.authorizer, authorizationScopes: [f.scopeName], integration: new HttpLambdaIntegration(`${method}${path}`, api) });
    }
    [dlq.metricApproximateNumberOfMessagesVisible(), worker.metricErrors(), worker.metricThrottles(),
      queue.metricApproximateAgeOfOldestMessage(), maintenance.metricApproximateAgeOfOldestMessage(),
      sweep.metricErrors(), dispatch.metricErrors()].forEach((metric, index) => {
      const alarm = new cw.Alarm(this, `Alarm${index}`, { metric, threshold: [3, 4].includes(index) ? 600 : 1,
        evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING });
      alarm.addAlarmAction(new actions.SnsAction(f.alarms));
    });
  }
}
