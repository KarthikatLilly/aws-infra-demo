# Deployment Guide — StatusPulse Infrastructure

## Environment → Branch → AWS Account Mapping

| GitHub branch | Environment | AWS account / profile | Protection |
|---------------|-------------|----------------------|------------|
| `main` | **prod** | Sandbox prod account | Required reviewers in GitHub env |
| `develop` | **qa** | Sandbox QA account | Optional reviewer |
| any other | **dev** | Personal sandbox | None |

A push to `main` or `develop` triggers `deploy.yml` automatically if files
under `cloudformation/` changed.  All other branches can be deployed via
`workflow_dispatch`.

---

## Where `AWS_DEPLOY_ROLE_ARN` Lives

The IAM role ARN is stored as a **GitHub environment variable** (not a secret —
role ARNs are not sensitive):

```
Repo → Settings → Environments → <env> → Environment variables
  AWS_DEPLOY_ROLE_ARN = arn:aws:iam::<ACCOUNT_ID>:role/statuspulse-gha-deploy
```

Each environment (`dev`, `qa`, `prod`) has its own variable pointing at the
correct IAM role in the corresponding AWS account.

The optional `AWS_VALIDATE_ROLE_ARN` variable is used by `validate.yml` for
the `aws cloudformation validate-template` step and should have read-only
permissions (or can be omitted — cfn-lint runs without AWS credentials).

---

## OIDC Setup (Step-by-Step)

### 1. Add the GitHub OIDC provider to your AWS account

In the AWS Console → IAM → Identity Providers → Add provider:

| Field | Value |
|-------|-------|
| Provider type | OpenID Connect |
| Provider URL | `https://token.actions.githubusercontent.com` |
| Audience | `sts.amazonaws.com` |

### 2. Create the deployment role

Create an IAM role with the following trust policy (replace `<OWNER>` and
`<REPO>`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        },
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

Attach a permissions policy that covers:
- `cloudformation:*`
- `dynamodb:*`
- `sns:*`
- `sqs:*`
- `apigateway:*`
- `iam:PassRole` (scoped to the API Gateway execution role)
- `iam:CreateRole`, `iam:AttachRolePolicy` etc. if CloudFormation creates IAM
  resources (needed because `--capabilities CAPABILITY_NAMED_IAM` is used)

### 3. Tighten for prod

For prod, add a condition to restrict to the `main` branch:

```json
"StringEquals": {
  "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:ref:refs/heads/main"
}
```

---

## Stack Naming Convention

```
statuspulse-{environment}-{service}
```

Examples:
- `statuspulse-dev-dynamodb`
- `statuspulse-qa-sns`
- `statuspulse-prod-api-gateway`

---

## Manual Deployment (No GitHub Actions)

```powershell
# From the repo root — deploy dev DynamoDB
pwsh statuspulse-infra/scripts/deploy.ps1 -Environment dev -Stack dynamodb

# Deploy all dev stacks in order
pwsh statuspulse-infra/scripts/deploy.ps1 -Environment dev

# Validate templates
pwsh statuspulse-infra/scripts/validate.ps1
```

---

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `Error: Could not assume role` in GHA | OIDC provider not added to the account, or trust policy condition mismatch | Verify the provider URL and the `sub` condition in the trust policy |
| `ROLLBACK_COMPLETE` on first deploy | Template error or missing permissions | Check CloudFormation events in Console; look for the specific resource that failed |
| SQS queue not receiving from SNS | Queue policy missing, or SNS subscription ARN mismatch | Verify `SnsTopicArn` parameter matches the SNS stack output |
| `POST /events` returns 403 | `ApiGatewayRoleArn` does not have `sqs:SendMessage` on the queue | Update the IAM role policy |
| `POST /events` returns 400 | Missing `x-message-group-id` header (required by FIFO) | Add the header in the client request |
| DynamoDB `ResourceInUseException` on re-deploy | `DeletionProtection` is `true`; stack tried to replace the table | Either update in-place or disable deletion protection first |
| cfn-nag `W` warnings in validate step | Non-blocking — cfn-nag flags best practices (e.g., no encryption in dev) | Safe to acknowledge; address before prod |
