# 05 — Enterprise Repo Bring-up (dc-status-infra) (my notes)

> Phase 5a deliverable for the StatusPulse → dc-status migration.
> Goal: replicate the proven sandbox pipeline (Phases 3–4) into the enterprise repo
> `EliLillyCo/dc-status-infra`, deploying into the AWS learner account.
> Outcome: full CI/CD pipeline green — all four stacks deployed via OIDC, no stored secrets.
> Phase 5b (the actual feature, the Lambda consumer) comes next.

---

## What this phase actually was

Not new architecture — a **migration + hardening** of the Phase 4 pipeline into a real enterprise
repo. The templates and workflow were ~90% the same as the sandbox. The other 10% — linting,
security scanning, IAM permission gaps, and a few template bugs — is what consumed the time. The
lesson: **moving working code into an enterprise repo surfaces a whole layer of strictness that a
personal sandbox never enforced.**

---

## How the CI/CD pipeline works (explain-it-to-anyone version)

> "This is the CI/CD pipeline. Any pull request or push that touches the CloudFormation templates or
> the workflows kicks it off. First it figures out which environment to target. Then it runs two
> checks in parallel: it **validates** the templates against AWS, and it **lints** them with cfn-lint
> (syntax/best-practice) and cfn-nag (security). If those pass, it deploys the four stacks **in
> dependency order** — DynamoDB, then SNS, then SQS, then API Gateway — each one authenticating to
> AWS with a short-lived OIDC token, no stored credentials. If every check and deploy passes, the
> change is safe to merge; merging to the right branch (or a manual run) is what actually updates the
> cloud. A reviewer with merge rights is the final gate."

### The stages, in order
1. **Resolve Target Environment** — reads the trigger (branch or manual choice) and outputs the env
   (`dev`/`qa`/`prod`). No AWS contact. Decides *where*.
2. **Validate CloudFormation Templates** — `aws cloudformation validate-template` per template.
   Catches structural errors before any deploy. (Uses OIDC.)
3. **Lint CloudFormation Templates** (parallel with validate) — runs **cfn-lint** (best practices +
   type checks) and **cfn-nag** (security scan). No AWS creds needed for lint.
4. **Deploy DynamoDB** → **Deploy SNS** → **Deploy SQS FIFO** → **Deploy API Gateway** — sequential,
   chained by `needs:`, because each stack consumes the previous one's exported outputs. Each assumes
   the deploy role via OIDC and runs `aws cloudformation deploy`.
5. **Deployment Summary** — prints a results table.

The order is **mandatory**: SNS exports the TopicArn that SQS subscribes to; SQS exports the QueueUrl
that API Gateway sends to. They cannot run in parallel.

---

## What changed from Phase 4 (small in count, big in time)

### Template fixes (cfn-lint / cfn-nag / CloudFormation)
1. **E3012 boolean type errors** — `ContentBasedDeduplication` (sqs-fifo) and
   `PointInTimeRecoveryEnabled` (dynamodb) used `!Equals [...]` where a literal boolean was required.
   Fixed with a named **Condition** + `!If [Condition, true, false]`. (dynamodb needed a new
   `EnablePitr` condition that was referenced but never defined — an undefined-condition bug.)
2. **SNS topic had to become FIFO** — the topic was a *standard* SNS topic, but a **FIFO SQS queue
   can only subscribe to a FIFO SNS topic**. Added `.fifo` suffix + `FifoTopic: true` +
   `ContentBasedDeduplication: true`. This was an **architecture correction**, not just a lint fix.
3. **Invalid SNS action** — the topic policy had `sns:Receive`, which is **not a real SNS action**
   (that's an SQS concept). Removed it; kept `sns:Subscribe`. (cfn-lint W3037)
4. **Unused condition + parameter** — removed `HasSnsIntegration` condition and the now-orphaned
   `SnsTopicStackName` parameter from api-gateway (and from the param file, to avoid a
   param/template mismatch). (cfn-lint W8001 / W2001)
5. **Empty Default on an ARN param** — `ApiGatewayRoleArn` had `Default: ''`, which cfn-lint checked
   against the IAM ARN regex and failed. Removed the default. (cfn-lint W1030)
6. **DynamoDB StreamArn output bug** — the template output `!GetAtt StatusTable.StreamArn` but the
   table had **no stream enabled**, so the attribute didn't exist → the stack created the table then
   **rolled back** on the unresolvable output. Removed the output. (This one wasn't lint — it only
   failed at deploy time.)
7. **API Gateway access log Format must be single line** — the `AccessLogSettings.Format` used a
   multiline YAML block that produced newlines; API Gateway rejects multiline log formats. Collapsed
   to a single-line JSON string.
8. (Optional) **`DependsOn: AccessLogGroup`** on the stage — insurance so the stage waits for the log
   group before configuring logging.

### Workflow (CI) fixes
9. **Workflows must be on the repo's default branch** — Actions only registers/shows workflows from
   the default branch. Had to merge to main (via PR) before the dispatch button appeared.
10. **cfn-nag install permission error** — `gem install cfn-nag` failed writing to the system gem
    path (`/var/lib/gems`). Fixed with `gem install --user-install cfn-nag` + adding the user gem bin
    to `$GITHUB_PATH`.
11. **Parameter format mismatch** — param files are in CloudFormation's native
    `[{ParameterKey, ParameterValue}]` array format, but `aws cloudformation deploy
    --parameter-overrides` wants `Key=Value` pairs. Fixed in `_deploy-stack.yml` by converting with
    `jq` into a bash array (`mapfile`), passed as `"${PARAM_ARR[@]}"` so values containing **commas**
    (the CORS lists!) stay intact.
12. **Added failure-event diagnostics** — a `if: failure()` step that dumps
    `describe-stack-events` for FAILED/ROLLBACK resources, so future failures show the real reason in
    the GitHub log instead of the generic "Failed to create/update the stack."

### IAM fixes (deploy role permissions)
The deploy role started with broad *service* FullAccess (CFN, DynamoDB, SNS, SQS, API Gateway, IAM)
but **no CloudWatch Logs permissions** — which API Gateway access logging needs. These surfaced one
at a time across multiple failed deploys:
13. `logs:CreateLogGroup` / `DeleteLogGroup` / `PutRetentionPolicy` / `TagResource` — manage the log
    group.
14. `logs:DescribeLogGroups` — **must be on `Resource: "*"`** (describe actions can't be ARN-scoped).
15. `logs:CreateLogDelivery` + the delivery family (`Get/Update/Delete/ListLogDeliveries`,
    `PutResourcePolicy`, `DescribeResourcePolicies`) — wires the API stage to the log group. Also
    `*`-scoped.

> **Key IAM lesson:** "FullAccess on the obvious services" still misses **cross-cutting**
> permissions like CloudWatch Logs delivery. API Gateway access logging touches three logs
> categories — group management, describe, and delivery — and all three had to be granted. Several of
> these actions (describe, delivery, resource-policy) **cannot be ARN-scoped** and require `*`.

---

## cfn-lint vs cfn-nag vs CORS (the three things to understand)

### cfn-lint
Best-practice + **type/structure** linter. Catches: wrong types (E3012 boolean), undefined
conditions, unused params/conditions, invalid service actions, malformed ARNs. **This repo's CI
treats cfn-lint warnings (W####) as failures** (non-zero exit), so even warnings must be cleared, not
just errors (E####). Run locally before every push.

### cfn-nag
**Security** scanner (separate tool, Ruby-based). Looks for risky patterns: wildcard IAM, open
security groups, unencrypted resources, public access. It runs *after* cfn-lint in the lint job. Its
findings are `F` (fail) vs `W` (warn); plain `cfn_nag_scan` fails only on `F` by default. The main
issue we hit with cfn-nag was the **install** (system gem path), not its findings.

### CORS
`CorsAllowOrigins: '*'` (open to any origin) is set for the POC. It's permissive — fine for dev/learner,
but for prod you'd narrow it to the real domain (`status.lilly.com`). cfn-nag / reviewers may flag `*`
+ auth headers as too open. Noted as Phase-5/prod hardening. Also relevant: the CORS method/header
lists contain **commas**, which is exactly why the param-passing fix (#11) had to preserve commas.

---

## CloudShell commands used constantly this phase

### Diagnose a failed stack (the single most useful one)
```bash
aws cloudformation describe-stack-events --stack-name <stack> \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
  --output table
```

### Check a stack's current state
```bash
aws cloudformation describe-stacks --stack-name <stack> --query "Stacks[0].StackStatus" --output text
```

### Delete a stuck stack + wait (needed after every first-create failure)
```bash
aws cloudformation delete-stack --stack-name <stack>
aws cloudformation wait stack-delete-complete --stack-name <stack>
```

### Add an inline policy to the deploy role (from a file, to avoid quoting issues)
```bash
cat > policy.json << 'EOF'
{ ...json... }
EOF
aws iam put-role-policy --role-name dc-status-poc-deploy-role --policy-name <name> --policy-document file://policy.json
```

### Verify identity / OIDC provider / existing resources
```bash
aws sts get-caller-identity
aws iam list-open-id-connect-providers
aws dynamodb list-tables --query "TableNames" --output table
```

### Lint locally before pushing (the discipline that saves public failures)
```bash
cfn-lint cloudformation/templates/*.yml
```

---

## Why "delete the stuck stack" kept recurring (and when it stops)
A stack that fails its **first create** lands in `ROLLBACK_COMPLETE`, which **cannot be updated** —
only deleted. So every failed first-create forced a delete before retry. **Once a stack succeeds
once**, this stops: future deploys are *updates*, and a failed update rolls back to the last good
state (`UPDATE_ROLLBACK_COMPLETE`) which *can* be updated again. DynamoDB/SNS/SQS never needed the
delete dance because they succeeded early; API Gateway needed it repeatedly because it kept failing
its first create. Now that it's green, it won't need deleting again.

---

## Enterprise-repo realities (different from the sandbox)
- **No environment access** — Maintainer role here does NOT include Settings → Environments (404).
  Worked around it with a **repository-scoped** `AWS_DEPLOY_ROLE_ARN` variable (resolves via fallback
  when no environment-scoped value exists).
- **Merge gated by manager** — can open PRs and push to `rc-infra-draft`, but merging to `main` needs
  the manager. The PR auto-runs validate + lint, so checks are visible before merge.
- **Pipeline runs are team-visible** — failures notify watchers, not just me. Hence the discipline of
  linting locally first.
- **Org Actions policy** — actions must be allowlisted; the ones used (`checkout`, `setup-python`,
  `configure-aws-credentials`) are permitted.

---

## State at end of Phase 5a
- ✅ All four stacks deployed to the **learner dev** environment via CI/OIDC — pipeline green.
- ✅ Templates pass cfn-lint and cfn-nag.
- ✅ Deploy role has the full permission set (services + CloudWatch Logs).
- ⬜ **Phase 5b — the Lambda consumer**: SQS → Lambda → DynamoDB (normalize service_id/status/
  checked_at → write pk=service_id, sk=checked_at). This is the actual feature; DynamoDB is still
  empty until it exists.
- ⬜ Least-privilege cleanup: re-scope the deploy role's broad FullAccess + `*` logs to custom
  scoped policies; rename `dc-status-poc-*` roles to drop the misleading `poc`.
- ⬜ Test the live path: `POST /events` with the `X-Message-Group-Id` header (FIFO requires it).
- ⬜ Promote to the real dev AWS account once the learner env is validated.

## The one-line summary
> Migrated the proven OIDC CI/CD pipeline into the enterprise repo. The architecture didn't change;
> getting past enterprise-grade linting (cfn-lint + cfn-nag), the param-format and FIFO/log template
> bugs, and the deploy role's missing CloudWatch Logs permissions is what took the time. Pipeline is
> now green end to end — next is the Lambda consumer.