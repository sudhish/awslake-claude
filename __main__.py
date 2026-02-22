import pulumi
import pulumi_aws as aws

bucket = aws.s3.Bucket(
    "my-test-bucket",
    tags={"Environment": "dev", "ManagedBy": "pulumi"},
)

pulumi.export("bucket_name", bucket.bucket)
pulumi.export("bucket_arn", bucket.arn)
