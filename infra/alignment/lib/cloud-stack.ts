import * as cdk from "aws-cdk-lib";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as db from "aws-cdk-lib/aws-dynamodb";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { HttpJwtAuthorizer } from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as sources from "aws-cdk-lib/aws-lambda-event-sources";
import * as destinations from "aws-cdk-lib/aws-lambda-destinations";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import * as sns from "aws-cdk-lib/aws-sns";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as secrets from "aws-cdk-lib/aws-secretsmanager";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";

export interface CloudProps extends cdk.StackProps {
  readonly stage: "dev" | "prod";
  readonly code: lambda.Code;
  readonly appleClientId: string;
  readonly appleTeamId: string;
  readonly appleKeyId: string;
  readonly appleSignInSecretArn: string;
  readonly callbackUrl: string;
  readonly domainPrefix: string;
}

export class CloudFoundationStack extends cdk.Stack {
  readonly accounts: db.Table;
  readonly subscriptions: db.Table;
  readonly pool: cognito.UserPool;
  readonly client: cognito.UserPoolClient;
  readonly api: apigw.HttpApi;
  readonly authorizer: HttpJwtAuthorizer;
  readonly scopeName = "paid-cloud/access";
  readonly common: Record<string, string>;
  readonly alarms: sns.Topic;

  constructor(scope: Construct, id: string, props: CloudProps) {
    super(scope, id, props);
    if (props.env?.region !== "eu-central-1") throw new Error("Cloud requires explicit eu-central-1 region");
    const table = (name: string, key: string) => new db.Table(this, name, {
      partitionKey: { name: key, type: db.AttributeType.STRING },
      billingMode: db.BillingMode.PAY_PER_REQUEST,
      encryption: db.TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    this.accounts = table("Accounts", "user_id");
    this.subscriptions = table("Subscriptions", "chain_key");
    this.pool = new cognito.UserPool(this, "AccountsPool", {
      selfSignUpEnabled: false,
      accountRecovery: cognito.AccountRecovery.NONE,
      deletionProtection: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const apple = new cognito.UserPoolIdentityProviderApple(this, "AppleSignIn", {
      userPool: this.pool, clientId: props.appleClientId, teamId: props.appleTeamId,
      keyId: props.appleKeyId,
      privateKeyValue: cdk.SecretValue.secretsManager(props.appleSignInSecretArn, { jsonField: "private_key" }),
      scopes: ["email", "name"],
      attributeMapping: { email: cognito.ProviderAttribute.APPLE_EMAIL },
    });
    const resource = this.pool.addResourceServer("PaidCloudScope", {
      identifier: "paid-cloud",
      scopes: [new cognito.ResourceServerScope({ scopeName: "access", scopeDescription: "Access own cloud account" })],
    });
    this.client = this.pool.addClient("NativeApp", {
      generateSecret: false,
      supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.APPLE],
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      accessTokenValidity: cdk.Duration.minutes(15),
      idTokenValidity: cdk.Duration.minutes(15),
      refreshTokenValidity: cdk.Duration.days(30),
      oAuth: {
        flows: { authorizationCodeGrant: true }, callbackUrls: [props.callbackUrl],
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL,
          cognito.OAuthScope.COGNITO_ADMIN, cognito.OAuthScope.resourceServer(resource,
            new cognito.ResourceServerScope({ scopeName: "access", scopeDescription: "Access own cloud account" }))],
      },
    });
    this.client.node.addDependency(apple);
    const domain = this.pool.addDomain("Login", { cognitoDomain: { domainPrefix: props.domainPrefix } });
    this.api = new apigw.HttpApi(this, "CloudApi");
    this.authorizer = new HttpJwtAuthorizer("Sessions", this.pool.userPoolProviderUrl, {
      jwtAudience: [this.client.userPoolClientId],
    });
    this.common = {
      ACCOUNTS_TABLE: this.accounts.tableName, SUBSCRIPTIONS_TABLE: this.subscriptions.tableName,
      APPLE_ENVIRONMENT: props.stage === "prod" ? "Production" : "Sandbox",
      JWT_ISSUER: this.pool.userPoolProviderUrl, JWT_CLIENT_ID: this.client.userPoolClientId,
      JWT_SCOPE: this.scopeName, USER_POOL_ID: this.pool.userPoolId,
    };
    const account = new lambda.Function(this, "AccountApi", {
      code: props.code, runtime: lambda.Runtime.PYTHON_3_12, handler: "backend.billing.api.account_handler",
      timeout: cdk.Duration.seconds(15), memorySize: 256, environment: this.common,
      logGroup: new logs.LogGroup(this, "AccountLogs", { retention: logs.RetentionDays.ONE_WEEK }),
    });
    this.accounts.grantReadWriteData(account);
    this.subscriptions.grantReadData(account);
    account.addToRolePolicy(new iam.PolicyStatement({ actions: ["cognito-idp:AdminDeleteUser"], resources: [this.pool.userPoolArn] }));
    for (const [method, path] of [[apigw.HttpMethod.GET, "/v1/me"],
      [apigw.HttpMethod.GET, "/v1/me/entitlements"], [apigw.HttpMethod.DELETE, "/v1/me"]] as const) {
      this.api.addRoutes({ path, methods: [method], authorizer: this.authorizer,
        authorizationScopes: [this.scopeName], integration: new HttpLambdaIntegration(`${method}${path}`, account) });
    }
    // Throttle the actual default stage, including the public notification verification route.
    const stage = this.api.defaultStage!.node.defaultChild as apigw.CfnStage;
    stage.defaultRouteSettings = { throttlingBurstLimit: 10, throttlingRateLimit: 5 };
    this.alarms = new sns.Topic(this, "OperationsAlarms");
    const alarm = new cw.Alarm(this, "AccountErrors", { metric: account.metricErrors(), threshold: 1,
      evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING });
    alarm.addAlarmAction(new actions.SnsAction(this.alarms));
    const apiAlarm = new cw.Alarm(this, "CloudApiServerErrors", { metric: this.api.metricServerError(),
      threshold: 1, evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING });
    apiAlarm.addAlarmAction(new actions.SnsAction(this.alarms));
    new cdk.CfnOutput(this, "ApiUrl", { value: this.api.apiEndpoint });
    new cdk.CfnOutput(this, "UserPoolId", { value: this.pool.userPoolId });
    new cdk.CfnOutput(this, "ClientId", { value: this.client.userPoolClientId });
    new cdk.CfnOutput(this, "LoginUrl", { value: domain.baseUrl() });
    new cdk.CfnOutput(this, "AlarmTopicArn", { value: this.alarms.topicArn });
  }
}

export interface BillingProps extends cdk.StackProps {
  readonly foundation: CloudFoundationStack;
  readonly code: lambda.Code;
  readonly appleApiSecretArn: string;
  readonly bundleId: string;
  readonly appAppleId?: string;
  readonly products: string[];
}

export class CloudBillingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: BillingProps) {
    super(scope, id, props);
    const f = props.foundation;
    if (!props.products.length || props.products.some(p => !p.trim())) throw new Error("Explicit Apple product allowlist required");
    if (f.common.APPLE_ENVIRONMENT === "Production" && !props.appAppleId?.match(/^[1-9][0-9]*$/)) {
      throw new Error("Production requires numeric appAppleId");
    }
    const inbox = new db.Table(this, "BillingEvents", {
      partitionKey: { name: "event_id", type: db.AttributeType.STRING },
      stream: db.StreamViewType.KEYS_ONLY, billingMode: db.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      encryption: db.TableEncryption.AWS_MANAGED, removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const deadLetters = new sqs.Queue(this, "DeadLetters", { retentionPeriod: cdk.Duration.days(14),
      encryption: sqs.QueueEncryption.SQS_MANAGED, enforceSSL: true });
    const maintenance = new sqs.Queue(this, "Maintenance", { visibilityTimeout: cdk.Duration.minutes(30),
      encryption: sqs.QueueEncryption.SQS_MANAGED, enforceSSL: true,
      deadLetterQueue: { queue: deadLetters, maxReceiveCount: 3 } });
    const environment = { ...f.common, BILLING_EVENTS_TABLE: inbox.tableName,
      APPLE_BUNDLE_ID: props.bundleId, APPLE_APP_ID: props.appAppleId ?? "",
      APPLE_PRODUCTS: JSON.stringify(props.products), APPLE_ROOTS_PATH: "/var/task/apple-roots" };
    const fn = (name: string, handler: string, seconds: number, credentials: boolean) => new lambda.Function(this, name, {
      code: props.code, runtime: lambda.Runtime.PYTHON_3_12, handler, timeout: cdk.Duration.seconds(seconds),
      memorySize: 256, reservedConcurrentExecutions: 2,
      environment: { ...environment, ...(credentials ? { APPLE_API_SECRET_ARN: props.appleApiSecretArn } : {}) },
      logGroup: new logs.LogGroup(this, `${name}Logs`, { retention: logs.RetentionDays.ONE_WEEK }),
    });
    const sync = fn("PurchaseSync", "backend.billing.api.sync_handler", 29, true);
    const webhook = fn("AppleWebhook", "backend.billing.api.webhook_handler", 29, false);
    const worker = fn("EventWorker", "backend.billing.worker.handler", 180, true);
    const sweep = fn("Reconciliation", "backend.billing.worker.sweep_handler", 600, true);
    sweep.addEnvironment("MAINTENANCE_QUEUE_URL", maintenance.queueUrl);
    maintenance.grantSendMessages(sweep);
    // A public webhook can only verify and insert durable events, never change ownership.
    inbox.grant(webhook, "dynamodb:PutItem");
    const apiKey = secrets.Secret.fromSecretCompleteArn(this, "AppleApiKey", props.appleApiSecretArn);
    for (const target of [sync, worker, sweep]) {
      f.accounts.grantReadWriteData(target);
      f.subscriptions.grantReadWriteData(target);
      apiKey.grantRead(target);
    }
    inbox.grantReadWriteData(worker);
    inbox.grantReadWriteData(sweep);
    worker.addEventSource(new sources.DynamoEventSource(inbox, { startingPosition: lambda.StartingPosition.TRIM_HORIZON,
      batchSize: 1, reportBatchItemFailures: true, retryAttempts: 5,
      maxRecordAge: cdk.Duration.hours(6), onFailure: new sources.SqsDlq(deadLetters) }));
    sweep.addEventSource(new sources.SqsEventSource(maintenance, { batchSize: 1, maxConcurrency: 2, reportBatchItemFailures: true }));
    new events.Rule(this, "ReconcileSchedule", { schedule: events.Schedule.rate(cdk.Duration.minutes(5)),
      targets: [new targets.LambdaFunction(sweep, { deadLetterQueue: deadLetters, retryAttempts: 2 })] });
    sweep.configureAsyncInvoke({ onFailure: new destinations.SqsDestination(deadLetters), retryAttempts: 2 });
    new apigw.HttpRoute(this, "SyncRoute", { httpApi: f.api, routeKey: apigw.HttpRouteKey.with("/v1/billing/apple/sync", apigw.HttpMethod.POST), authorizer: f.authorizer,
      authorizationScopes: [f.scopeName], integration: new HttpLambdaIntegration("PurchaseSync", sync) });
    new apigw.HttpRoute(this, "WebhookRoute", { httpApi: f.api, routeKey: apigw.HttpRouteKey.with("/v1/webhooks/apple", apigw.HttpMethod.POST),
      integration: new HttpLambdaIntegration("AppleNotifications", webhook) });
    const metrics = [deadLetters.metricApproximateNumberOfMessagesVisible(), worker.metricErrors(),
      sweep.metricErrors(), worker.metricThrottles(), sweep.metricThrottles(),
      new cw.Metric({ namespace: "AWS/Lambda", metricName: "IteratorAge", dimensionsMap: { FunctionName: worker.functionName }, statistic: "Maximum" })];
    const backlog = new cw.Alarm(this, "MaintenanceBacklogAge", {
      metric: maintenance.metricApproximateAgeOfOldestMessage(), threshold: 600,
      evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING });
    backlog.addAlarmAction(new actions.SnsAction(f.alarms));
    metrics.forEach((metric, index) => {
      const alarm = new cw.Alarm(this, `BillingAlarm${index}`, { metric, threshold: index === 5 ? 300000 : 1,
        evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING });
      alarm.addAlarmAction(new actions.SnsAction(f.alarms));
    });
  }
}
