# 04 — CI/CD with GitHub Actions + OIDC (my notes)

> Phase 4 deliverable for StatusPulse infra POC.
> Goal: stop deploying by hand in CloudShell; make a push (or a manual click) deploy the
> CloudFormation stacks automatically, authenticating to AWS with **no stored secrets**.
> Outcome: a green pipeline that deploys dynamodb → sns → sqs-fifo → api-gateway to dev,
> using short-lived OIDC credentials, with a full CloudTrail audit trail.

This replaces manual “clickops”/CloudShell with a reproducible pipeline.

---

## 1. What I built (the big picture)

```
git push / manual "Run workflow"
        │
        ▼
GitHub Actions (deploy.yml)
        │  resolve env → validate (cfn-lint) → deploy 4 stacks in order
        ▼
GitHub mints a short-lived OIDC token  (a signed JWT: "I am repo X, environment dev")
        │
        ▼
AWS STS: AssumeRoleWithWebIdentity   (checks the role's trust policy)
        │  token matches sub + aud conditions → issues TEMPORARY credentials (expire in minutes)
        ▼
aws cloudformation deploy ...   (runs with those temp creds)
        │
        ▼
AWS infra created/updated  →  temp creds expire & vanish
```

The two workflow files:
- **deploy.yml** — the *orchestrator*. Resolves which environment, validates templates, then calls
  the reusable workflow four times in dependency order.
- **_deploy-stack.yml** — the *reusable worker*. For one stack: checkout → assume role via OIDC →
  `cloudformation deploy` → show outputs. Called once per stack.

---

## 2. OIDC — the core concept (why no secrets)

**The old way (bad):** create a long-lived IAM access key (AKIA...), paste it into GitHub Secrets.
That key never expires, can be leaked, committed by accident, or stolen, and must be rotated.

**The OIDC way :** no stored key at all.
- GitHub can act as an **OIDC identity provider** — it can issue signed tokens proving "this workflow
  run belongs to repo `KarthikatLilly/aws-infra-demo`."
- AWS is told to **trust** that provider (an IAM OIDC identity provider for
  `token.actions.githubusercontent.com`).
- An IAM **role** has a **trust policy** saying "tokens from that provider, matching my repo, may
  assume me."
- At runtime, GitHub mints a fresh token → AWS STS verifies it → returns **temporary** credentials
  (prefix `ASIA...`, valid ~1 hour) → they run the deploy → they expire.

**Key takeaway:** the only thing stored in GitHub is the role **ARN** (a plain identifier, harmless
on its own). Assuming the role requires a valid token that *only GitHub can mint for my repo*. There
is no permanent secret anywhere to leak.

### Two halves of the role (don't confuse them)
- **Trust policy** = *who may assume the role* (the OIDC provider + repo conditions). Governs login.
- **Permissions policy** = *what the role may do once assumed* (CloudFormation, DynamoDB, etc.).
  Governs actions.
Both must be right: trust lets you in, permissions let you act.

### The trust policy I have
```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::024111598068:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:KarthikatLilly/aws-infra-demo:*" }
  }
}
```
- `aud` (audience) = `sts.amazonaws.com` — the token is meant for AWS STS.
- `sub` (subject) = `repo:KarthikatLilly/aws-infra-demo:*` — any branch/workflow in my repo.
  (For prod hardening, scope this to specific branches/environments instead of `*`.)

---

## 3. How the two workflows connect (reusable workflows)

`deploy.yml` calls `_deploy-stack.yml` via `uses: ./.github/workflows/_deploy-stack.yml` and passes
inputs (stack-name, template-file, parameter-file, region, environment). The four deploy jobs are
chained with `needs:` so they run **serially in dependency order**:

```
deploy-dynamodb  (needs: validate)
deploy-sns       (needs: deploy-dynamodb)
deploy-sqs       (needs: deploy-sns)
deploy-api       (needs: deploy-sqs)
```

This order is mandatory: sns exports the TopicArn that sqs needs; sqs exports the queue URL that api
needs. The UI may *look* parallel (next job spins up as the previous finishes) but the `needs` chain
guarantees order.

### Environment resolution (a real gotcha I hit)
deploy.yml maps branch → environment:
- push to `main`   → **prod**
- push to `develop`→ **qa**
- manual dispatch  → whatever I pick (dev/qa/prod)

So a push to main tries **prod**. I only configured **dev**, so pushing to main failed (see Error 6).
For the POC I deploy to dev via **manual dispatch** (Run workflow → environment: dev).

---

## 4. The errors I hit and fixed (the real debugging story)

Each of these was a separate failed run. This sequence *is* the learning.

### Error 1 — Actions didn't detect the workflow at all
- **Symptom:** Actions tab showed the "get started" screen; "Deploy StatusPulse" never appeared.
- **Cause:** workflow files were at `statuspulse-infra/.github/workflows/`. GitHub only reads
  `.github/workflows/` at the **repo root**. Nested ones are ignored.
- **Fix:** `git mv statuspulse-infra/.github .github` (move to root), commit, push.
- **Theory:** code/templates can live anywhere; **workflows must be at root `.github/workflows/`** —
  the one rigid location rule in GitHub Actions.

### Error 2 — Startup failure: "id-token: write but is only allowed 'none'"
- **Symptom:** run failed instantly at startup; no jobs ran.
- **Cause:** `_deploy-stack.yml` (the called workflow) requested `id-token: write`, but the caller
  `deploy.yml` had no top-level `permissions` block, so it passed down `id-token: none`.
- **Fix:** add to deploy.yml at the top level (before `jobs:`):
  ```yaml
  permissions:
    id-token: write
    contents: read
  ```
- **Theory:** a **reusable workflow can never have more permission than the caller grants it**. The
  caller must grant `id-token: write` for OIDC to work in the called workflow.

### Error 3 — cfn-lint E3012 (fatal): Fn::Equals is not of type 'boolean'
- **File:** sns.yml. `RawMessageDelivery: !Equals [!Ref InitialSubscriptionProtocol, sqs]`
- **Cause:** `RawMessageDelivery` expects a literal boolean; an inline `!Equals` in that spot is a
  type mismatch (same family as the earlier "Fn::Equals cannot be partially collapsed" on sqs).
- **Fix:** `RawMessageDelivery: true`. Safe because that subscription only exists when an endpoint is
  supplied (a Condition), which dev doesn't.
- **Theory:** intrinsic functions must return the *type* the property expects. `E####` = error
  (fails build); `W####` = warning.

### Error 4 — cfn-lint W2001: parameter ContentBasedDeduplication not used
- **File:** sqs-fifo.yml. The param was declared but the queues hardcoded the value, so it was never
  referenced.
- **Cause + important nuance:** normally W = warning (non-fatal), but **this repo's cfn-lint exits
  non-zero on warnings too** (exit code 4), so even warnings fail the build.
- **Fix:** wire the parameter in properly via a Condition + `!If`:
  ```yaml
  Conditions:
    UseContentBasedDeduplication: !Equals [!Ref ContentBasedDeduplication, "true"]
  # on each queue:
    ContentBasedDeduplication: !If [UseContentBasedDeduplication, true, false]
  ```
- **Theory:** a declared-but-unused parameter is dead config; the fix makes the param actually
  control behavior (flipping it to "false" now does something).

### Error 5 — cfn-lint W3011: need both DeletionPolicy and UpdateReplacePolicy
- **File:** dynamodb.yml. Had `DeletionPolicy: Retain` but not `UpdateReplacePolicy: Retain`.
- **Fix:** add `UpdateReplacePolicy: Retain` beside it (same indent level as `Type`/`Properties`):
  ```yaml
  StatusPulseTable:
    Type: AWS::DynamoDB::Table
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties: ...
  ```
- **Theory:** `DeletionPolicy` protects the resource when the **stack** is deleted;
  `UpdateReplacePolicy` protects it when an **update would replace** it. For a data store you want
  both — otherwise a replacing change could silently destroy the table.
- **Debugging lesson:** the first "fix" appeared to still fail with the same error + same line number.
  Identical error + identical line = the corrected file never ran (wrong branch / not pushed). Always
  confirm the fix is on the branch the workflow runs from (`git log --oneline`, `git branch`).

### Error 6 — "Could not load credentials" on Deploy (the prod trap)
- **Symptom:** validation passed, then "Configure AWS credentials via OIDC" failed with
  "Could not load credentials from any providers." Job name said **statuspulse-prod-dynamodb**.
- **Cause:** I pushed to `main` → resolved to **prod**. The `AWS_DEPLOY_ROLE_ARN` variable was only
  set on the **dev** environment, so under prod it resolved to **empty** → empty `role-to-assume` →
  no credentials.
- **Fix:** don't deploy to prod. Trigger manually with **environment: dev** (where the variable is
  set). (Copilot wrongly suggested adding permissions/inputs — those were already correct; the real
  signal was the **prod** in the job name + the missing prod variable.)
- **Theory:** `vars.X` resolves **environment-scoped first**. A variable set on dev does not exist for
  prod. Match the environment you trigger to one that's actually configured.

---

## 5. Proof it worked (verification)

### In GitHub
Run #6, manual dispatch, environment dev → **Success**, 2m 31s. All six jobs green:
Resolve environment → Validate templates → Deploy dynamodb → sns → sqs-fifo → api-gateway.

### In AWS — CloudTrail (the audit trail)
CloudTrail → Event history → filter Event name = `AssumeRoleWithWebIdentity`. Saw **four** events
(one per stack), timestamped to the run, with:
- **User name:** `repo:KarthikatLilly/aws-infra-demo:environment:dev` — the OIDC token's identity.
- **Event source:** `sts.amazonaws.com`.
- **Resource name:** `ASIA...` — note the **ASIA prefix = TEMPORARY** STS credentials, not `AKIA`
  (which would be a permanent key). Visible proof that no long-lived keys were used.
- `role-session-name` = `gha-<stack>-<run_id>` (set in the workflow) makes each deploy traceable.

### Where else to look in AWS
- **IAM → Identity providers** → `token.actions.githubusercontent.com` exists.
- **IAM → Roles → statuspulse-gha-deploy-role** → Trust relationships (the conditions), Last activity
  (recent use). No access keys on the role (roles never have long-lived keys).
- **CloudFormation** → the four `statuspulse-dev-*` stacks show recent UPDATE/CREATE_COMPLETE.

---

## 6. "Are any AWS keys exposed?" — No.
- No long-lived keys exist anywhere: not in GitHub, not in the repo, not in the workflow files.
- GitHub stores only the role **ARN** (an identifier; useless without a valid OIDC token from my repo).
- Every credential used was temporary (`ASIA...`), minted at runtime, expired after the job.
- The trust policy `sub` gates who can assume the role; mine is repo-wide (`:*`) — fine for POC,
  tighten to branches/environments for prod.

---

## 7. Cosmetic warnings (safe to ignore)
The run showed "Node.js 20 deprecated" warnings for `checkout@v4`, `setup-python@v5`,
`configure-aws-credentials@v4`. These are about the actions' runtime, don't affect the deploy, and go
away when I bump to newer action versions later. Not a failure.

---

## 8. The full fix trail (commit history, in order)
1. `fix: move .github/workflows to repo root so Actions detects them`
2. `fix: grant id-token write at deploy.yml top level for OIDC in reusable workflow`
3. `Update sns.yml rawmsg delivery update` (E3012: RawMessageDelivery → literal true)
4. `fix(sqs-fifo): wire ContentBasedDeduplication param via Condition to clear cfn-lint W2001`
5. `fix(dynamodb): add UpdateReplacePolicy Retain alongside DeletionPolicy to clear cfn-lint W3011`

---

## 9. Phase 4 done — checklist
- ✅ Workflows detected (at repo root)
- ✅ OIDC trust configured (provider + scoped trust policy)
- ✅ Reusable workflow + orchestrator, stacks deploy in dependency order
- ✅ Templates pass cfn-lint (all E and W cleared; warnings are fatal in this repo)
- ✅ Pipeline deploys to dev via manual dispatch — Success
- ✅ Verified in CloudTrail (AssumeRoleWithWebIdentity, temporary ASIA creds)
- ✅ Confirmed: no stored secrets, no exposed long-lived keys
- ⬜ Tighten the deploy role to least privilege (currently broad FullAccess — Phase 5)
- ⬜ Configure prod environment + variable + scoped trust if main→prod is wanted (later)

## 10. Open questions / Phase 5
- Replace the deploy role's broad managed policies (CFN/DDB/SNS/SQS/APIGW/IAM FullAccess) with a
  scoped custom policy — same least-privilege lesson as the API Gateway role in Phase 3.
- Scope the trust policy `sub` from `:*` to specific branches/environments.
- Decide whether to wire prod (separate role, environment, approvals) or keep POC at dev.
- Bump action versions to clear the Node 20 deprecation warnings.
```