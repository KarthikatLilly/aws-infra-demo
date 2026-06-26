# aws-infra-demo

Personal learning repo for AWS Infrastructure as Code (IaC).

This repo:
- Mirrors the structure of the enterprise dc-status-infra repo
- Recreates a CloudFormation-based serverless ingestion stack
- Practices GitHub Actions OIDC-based deployment

Architecture target (personal IaC mirror):
- API Gateway HTTP API
- SNS FIFO topic
- SQS FIFO queue + DLQ
- DynamoDB single-table store
- Deployed through GitHub Actions + CloudFormation

This repo is for personal learning. No Lilly data is stored or processed here.
Resources are deployed only to a personal sandbox or AWS Learner Env.
