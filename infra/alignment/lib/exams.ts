import * as cdk from "aws-cdk-lib";
import * as db from "aws-cdk-lib/aws-dynamodb";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { Construct } from "constructs";

/** Private source packages and durable, owner-scoped examination progress. */
export class ExamStorage extends Construct {
  readonly table: db.Table;
  readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string) {
    super(scope, id);
    this.table = new db.Table(this, "State", {
      partitionKey: { name: "pk", type: db.AttributeType.STRING },
      sortKey: { name: "sk", type: db.AttributeType.STRING },
      billingMode: db.BillingMode.PAY_PER_REQUEST,
      encryption: db.TableEncryption.AWS_MANAGED,
      deletionProtection: true, removalPolicy: cdk.RemovalPolicy.RETAIN,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
    });
    this.bucket = new s3.Bucket(this, "Packages", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      encryption: s3.BucketEncryption.S3_MANAGED, enforceSSL: true,
      versioned: true, removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    new cdk.CfnOutput(this, "TableName", { value: this.table.tableName });
    new cdk.CfnOutput(this, "BucketName", { value: this.bucket.bucketName });
  }

  bind(target: lambda.Function) {
    target.addEnvironment("EXAMS_TABLE", this.table.tableName);
    target.addEnvironment("EXAMS_BUCKET", this.bucket.bucketName);
    this.table.grantReadWriteData(target);
    // Upload/publication is performed separately by an authenticated administrator.
    this.bucket.grantRead(target, "exams/*");
  }
}

export const EXAM_ROUTES: readonly (readonly [apigw.HttpMethod, string])[] = [
  [apigw.HttpMethod.GET, "/v1/exams"],
  [apigw.HttpMethod.GET, "/v1/exams/{id}"],
  [apigw.HttpMethod.GET, "/v1/exams/{id}/revisions/{revision}"],
  [apigw.HttpMethod.GET, "/v1/exams/{id}/revisions/{revision}/sources/{source_id}/download"],
  [apigw.HttpMethod.GET, "/v1/exam-attempts"],
  [apigw.HttpMethod.POST, "/v1/exam-attempts"],
  [apigw.HttpMethod.GET, "/v1/exam-attempts/{id}"],
  [apigw.HttpMethod.PUT, "/v1/exam-attempts/{id}"],
  [apigw.HttpMethod.POST, "/v1/exam-attempts/{id}/submit"],
  [apigw.HttpMethod.GET, "/v1/exam-attempts/{id}/assessment/{task_id}"],
  [apigw.HttpMethod.POST, "/v1/exam-attempts/{id}/assessment/{task_id}"],
  [apigw.HttpMethod.POST, "/v1/exam-assessments"],
];
