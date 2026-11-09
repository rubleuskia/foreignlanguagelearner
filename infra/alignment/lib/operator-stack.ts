import * as cdk from "aws-cdk-lib";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as db from "aws-cdk-lib/aws-dynamodb";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { HttpJwtAuthorizer } from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import * as sns from "aws-cdk-lib/aws-sns";
import * as actions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";
import { DEPLOYMENT_REGION } from "./region";

export const OPERATOR_MODEL = "qwen.qwen3-235b-a22b-2507-v1:0";

export class OperatorStack extends cdk.Stack {
  readonly api: apigw.HttpApi;
  readonly authorizer: HttpJwtAuthorizer;
  readonly table: db.Table;
  readonly common: Record<string, string>;
  readonly alarms: sns.Topic;

  constructor(scope: Construct, id: string, props: cdk.StackProps & {
    readonly code: lambda.Code; readonly operatorUsername: string; readonly dailyModelLimit: number;
    readonly alignmentEnabled?: boolean;
  }) {
    super(scope, id, props);
    if (props.env?.region !== DEPLOYMENT_REGION) throw new Error(`Operator requires ${DEPLOYMENT_REGION}`);
    if (!/^[A-Za-z0-9_.@+-]{1,64}$/.test(props.operatorUsername)) throw new Error("Invalid operatorUsername");
    if (!Number.isInteger(props.dailyModelLimit) || props.dailyModelLimit < 1 || props.dailyModelLimit > 1000) {
      throw new Error("dailyModelLimit must be 1..1000");
    }
    const pool = new cognito.UserPool(this, "OperatorPool", {
      selfSignUpEnabled: false, signInAliases: { username: true }, signInCaseSensitive: true,
      accountRecovery: cognito.AccountRecovery.NONE, deletionProtection: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      passwordPolicy: { minLength: 14, requireDigits: true, requireLowercase: true,
        requireUppercase: true, requireSymbols: true },
    });
    const client = pool.addClient("OperatorClient", {
      generateSecret: false, preventUserExistenceErrors: true, enableTokenRevocation: true,
      disableOAuth: true,
      authFlows: { userSrp: true, userPassword: true },
      accessTokenValidity: cdk.Duration.minutes(15), idTokenValidity: cdk.Duration.minutes(15),
      refreshTokenValidity: cdk.Duration.days(1),
    });
    this.table = new db.Table(this, "OperatorRequests", {
      partitionKey: { name: "id", type: db.AttributeType.STRING },
      billingMode: db.BillingMode.PAY_PER_REQUEST, encryption: db.TableEncryption.AWS_MANAGED,
      timeToLiveAttribute: "delete_after", removalPolicy: cdk.RemovalPolicy.RETAIN,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: false },
    });
    this.api = new apigw.HttpApi(this, "OperatorApi");
    this.authorizer = new HttpJwtAuthorizer("OperatorJwt", pool.userPoolProviderUrl,
      { jwtAudience: [client.userPoolClientId] });
    const stage = this.api.defaultStage!.node.defaultChild as apigw.CfnStage;
    stage.defaultRouteSettings = { throttlingBurstLimit: 4, throttlingRateLimit: 2 };
    const accessLogs = new logs.LogGroup(this, "AccessLogs", { retention: logs.RetentionDays.ONE_WEEK });
    stage.accessLogSettings = { destinationArn: accessLogs.logGroupArn,
      format: JSON.stringify({ requestId: "$context.requestId", status: "$context.status",
        routeKey: "$context.routeKey", latency: "$context.responseLatency" }) };
    this.common = { JWT_ISSUER: pool.userPoolProviderUrl, JWT_CLIENT_ID: client.userPoolClientId,
      OPERATOR_USERNAME: props.operatorUsername, OPERATOR_TABLE: this.table.tableName,
      DAILY_MODEL_LIMIT: String(props.dailyModelLimit), OPERATOR_ALIGNMENT: String(props.alignmentEnabled ?? true) };
    const handlerLogs = new logs.LogGroup(this, "HandlerLogs", { retention: logs.RetentionDays.ONE_WEEK });
    const api = new lambda.Function(this, "OperatorHandler", {
      runtime: lambda.Runtime.PYTHON_3_12, code: props.code, handler: "backend.private_cloud.api.handler",
      memorySize: 256, timeout: cdk.Duration.seconds(28), reservedConcurrentExecutions: 2,
      environment: this.common, logGroup: handlerLogs,
    });
    this.table.grantReadWriteData(api);
    api.addToRolePolicy(new iam.PolicyStatement({ actions: ["bedrock:InvokeModel"],
      resources: [`arn:${this.partition}:bedrock:${this.region}::foundation-model/${OPERATOR_MODEL}`] }));
    const integration = new HttpLambdaIntegration("OperatorIntegration", api);
    for (const [method, path] of [[apigw.HttpMethod.GET, "/v1/health"], [apigw.HttpMethod.GET, "/v1/me"],
      [apigw.HttpMethod.POST, "/v1/context-analyses"], [apigw.HttpMethod.POST, "/v1/word-explanations"],
      [apigw.HttpMethod.GET, "/v1/requests/{id}"], [apigw.HttpMethod.GET, "/v1/requests/by-key/{key}"]] as const) {
      this.api.addRoutes({ path, methods: [method], authorizer: this.authorizer,
        authorizationScopes: ["aws.cognito.signin.user.admin"], integration });
    }
    this.alarms = new sns.Topic(this, "OperatorAlarms");
    const modelFailures = new logs.MetricFilter(this, "ModelFailures", { logGroup: handlerLogs,
      filterPattern: logs.FilterPattern.stringValue("$.event", "=", "model_failed"),
      metricNamespace: "FLL/Operator", metricName: "ModelFailures", metricValue: "1" });
    const apiFailures = new logs.MetricFilter(this, "ApiFailures", { logGroup: handlerLogs,
      filterPattern: logs.FilterPattern.stringValue("$.event", "=", "operator_api_error"),
      metricNamespace: "FLL/Operator", metricName: "ApiFailures", metricValue: "1" });
    const modelLatency = new logs.MetricFilter(this, "ModelLatency", { logGroup: handlerLogs,
      filterPattern: logs.FilterPattern.stringValue("$.event", "=", "model_completed"),
      metricNamespace: "FLL/Operator", metricName: "ModelLatency", metricValue: "$.duration_ms",
      unit: cw.Unit.MILLISECONDS });
    for (const field of ["input_tokens", "output_tokens"]) {
      new logs.MetricFilter(this, field, { logGroup: handlerLogs,
        filterPattern: logs.FilterPattern.stringValue("$.event", "=", "model_completed"),
        metricNamespace: "FLL/Operator", metricName: field, metricValue: `$.${field}` });
    }
    for (const [index, metric] of [api.metricErrors(), api.metricThrottles(), this.api.metricServerError(),
      modelFailures.metric(), apiFailures.metric()].entries()) {
      new cw.Alarm(this, `Alarm${index}`, { metric, threshold: 1, evaluationPeriods: 1,
        treatMissingData: cw.TreatMissingData.NOT_BREACHING }).addAlarmAction(new actions.SnsAction(this.alarms));
    }
    new cw.Alarm(this, "ModelLatencyAlarm", { metric: modelLatency.metric({ statistic: "Maximum" }),
      threshold: 20000, evaluationPeriods: 1, treatMissingData: cw.TreatMissingData.NOT_BREACHING })
      .addAlarmAction(new actions.SnsAction(this.alarms));
    new cdk.CfnOutput(this, "ApiUrl", { value: this.api.apiEndpoint });
    new cdk.CfnOutput(this, "UserPoolId", { value: pool.userPoolId });
    new cdk.CfnOutput(this, "ClientId", { value: client.userPoolClientId });
    new cdk.CfnOutput(this, "OperatorUsername", { value: props.operatorUsername });
    new cdk.CfnOutput(this, "BedrockModelId", { value: OPERATOR_MODEL });
    new cdk.CfnOutput(this, "AlarmTopicArn", { value: this.alarms.topicArn });
  }
}
