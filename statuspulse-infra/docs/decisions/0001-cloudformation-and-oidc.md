# ADR 0001 — CloudFormation + GitHub Actions OIDC

**Status**: Accepted  
**Date**: 2026-06-26  
**Author**: Personal learning project

---

## Context

This project is a personal learning replica of the enterprise
`EliLillyCo/dc-status-infra` pattern.  The goal is to practice
infrastructure-as-code techniques using the same tools and conventions
used in production at scale, so that skills transfer directly.

The key questions at the start were:

1. **IaC tool**: CloudFormation vs CDK vs Terraform vs SAM?
2. **CI/CD**: GitHub Actions vs CircleCI vs Jenkins?
3. **AWS credentials in CI**: long-lived IAM user keys vs OIDC?

---

## Decision

Use **AWS CloudFormation** (raw YAML templates) orchestrated by
**GitHub Actions** using **OIDC** (no long-lived AWS credentials).

---

## Rationale

### CloudFormation

- **Enterprise alignment**: `dc-status-infra` uses CloudFormation.  Learning
  raw CFN builds an understanding of the resource model that CDK and SAM
  abstract away — that understanding is essential for debugging.
- **No local toolchain to install**: CFN templates are YAML files validated by
  the AWS API; only `aws-cli` and optionally `cfn-lint` are needed.
- **Explicit resource lifecycle**: Conditions, DeletionPolicy, and Outputs are
  all visible in the template rather than generated.  This forces thinking
  about what happens when a stack is updated or deleted.
- **CDK/SAM trade-off**: CDK would reduce boilerplate but adds a synthesis step
  and a layer of indirection.  For a learning project where reading every
  property is the point, raw CFN is preferable.
- **Terraform trade-off**: Terraform is excellent for multi-cloud but requires
  state backend management and a separate provider ecosystem.  For an
  AWS-only project mirroring an existing CFN repo, staying in CFN avoids
  needless divergence.

### GitHub Actions OIDC

- **No long-lived credentials**: OIDC tokens are short-lived JWTs issued by
  GitHub and exchanged for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`.
  No IAM user, no access key stored in GitHub Secrets.
- **Enterprise alignment**: `dc-status-infra` uses the same OIDC pattern.
- **Auditability**: Every GitHub Actions run produces a CloudTrail entry with
  the role session name `gha-<stack>-<run_id>`, making it trivial to tie an
  AWS API call back to a specific workflow run.
- **Fine-grained trust**: The IAM trust policy can scope to a specific branch
  (e.g., only `main` can assume the prod role), preventing accidental
  production deploys from feature branches.
- **GitHub Actions vs alternatives**: GitHub Actions was chosen over CircleCI
  or Jenkins because the workflow files live alongside the templates in the
  same repository, reducing cognitive overhead and matching the enterprise
  pattern.

---

## Consequences

- Templates must be valid CloudFormation YAML — validated by `cfn-lint` and
  `aws cloudformation validate-template` on every PR.
- Cross-stack values (e.g., the SNS topic ARN passed to the SQS stack) must
  be threaded through parameter files rather than resolved automatically —
  this is intentional: it makes dependencies explicit and mirrors what the
  enterprise repo does.
- The OIDC role ARN is stored as a GitHub environment variable, not a secret.
  Role ARNs are not sensitive; keeping them as variables (not secrets) makes
  debugging easier.
- `DeletionPolicy: Retain` on the DynamoDB table means that deleting the
  CloudFormation stack does NOT delete the table — this is a deliberate safety
  net for prod-like environments.
