# 05b — Processor Lambda (SQS → DynamoDB) (my notes)

> Phase 5b deliverable. This is the piece that makes the system actually *do* something —
> the consumer that reads events off the queue and writes them to the database.
> After this, DynamoDB stops being empty.
> Status at end of phase: deployed via the OIDC pipeline, verified end-to-end with live POSTs.

---

## The one-paragraph summary

Everything before this phase built the *plumbing*: a way for events to arrive (API Gateway),
a place for them to wait safely (SQS FIFO), and a place to store them (DynamoDB). But nothing
connected the queue to the database — messages would arrive and just sit there. **The Processor
Lambda is that connection.** It automatically wakes up whenever a message lands in the queue, reads
it, cleans it up, and writes it to DynamoDB. It's the "worker" of the system.

---

## What the Lambda actually does (in plain terms)

Think of the SQS queue as a **conveyor belt** with packages (messages) on it. The Lambda is a
**worker standing at the end of the belt**. Every time packages show up, the worker:

1. **Picks up** a batch of messages (up to 10 at a time — the `BatchSize`).
2. For each message, **opens it** (parses the JSON body).
3. **Checks it's valid** — does it have a `service_id` and a `checked_at`? If not, throws it away
   (logs "skipping") and moves on, so one bad package doesn't stop the line.
4. **Writes it** to DynamoDB as a row: `pk = service_id`, `sk = checked_at`, plus `status` and the
   raw payload.
5. Once the batch is done, SQS **deletes** those messages (they're processed).

The worker isn't running all the time — it's **event-driven**. It only spins up when there's work,
processes it in milliseconds, and goes back to sleep. You pay only for the milliseconds it runs.

### The actual handler logic
```python
import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

def handler(event, context):
    processed = 0
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
        except (ValueError, KeyError):
            print(f"Skipping unparseable record: {record.get('messageId')}")
            continue

        service_id = body.get("service_id")
        status = body.get("status")
        checked_at = body.get("checked_at")

        if not service_id or not checked_at:
            print(f"Skipping record missing keys: {body}")
            continue

        table.put_item(Item={
            "pk": service_id,
            "sk": checked_at,
            "status": status,
            "raw": json.dumps(body),
        })
        processed += 1
        print(f"Wrote pk={service_id} sk={checked_at} status={status}")

    return {"processed": processed}
```

The `print` lines are deliberate — they show up in CloudWatch Logs so you can watch exactly what
the worker did with each message. This is how we verified the tests.

---

## The data model — why pk = service_id, sk = checked_at

DynamoDB tables use a **partition key (pk)** and an optional **sort key (sk)**. Together they're the
unique address of a row. We chose:
- **pk = service_id** — groups all events for one service together (all "jira" events live under one
  partition).
- **sk = checked_at** — orders those events by time within the service.

**Why this matters:**
- **History for free** — every status check at a new timestamp is a new row under the same service.
  So `jira` at 10:00 (degraded) and `jira` at 12:00 (operational) are two rows — a time series. This
  is the "current + status_checks: history" idea from the architecture diagram.
- **Current status** — to ask "is jira up right now?", query `pk = jira`, take the row with the
  newest `sk`.
- **Idempotency** — if the *same* event (same service + same timestamp) is processed twice, it writes
  to the *same* pk+sk address, so it overwrites rather than duplicating. No double-counting.

---

## How the Lambda gets triggered — the Event Source Mapping

This is the key wiring concept. The Lambda doesn't "watch" the queue itself. Instead, AWS provides a
managed connector called an **Event Source Mapping (ESM)**. You tell it: "this queue → this function."
AWS then **polls the queue for you** behind the scenes, and whenever messages arrive, it invokes the
Lambda with a batch of them. You don't write any polling code.

```yaml
SqsEventSourceMapping:
  Type: AWS::Lambda::EventSourceMapping
  Properties:
    EventSourceArn: <the SQS queue ARN, imported from the SQS stack>
    FunctionName: <the Lambda>
    BatchSize: 10
    Enabled: true
```

The moment this resource is created with `Enabled: true`, the connection goes live — AWS starts
polling and the Lambda starts processing. This is why, right after the stack deployed, old test
messages in the queue got processed automatically.

---

## Why INLINE code (ZipFile) instead of S3 — important decision

Lambda needs its code *somewhere CloudFormation can read it.* There are two ways:

### Option A — Inline (`ZipFile`) — WHAT WE USED
The Python code is written **directly inside the CloudFormation template** as a `ZipFile` block.
CloudFormation packages it into the Lambda for you.

**Why we chose this:**
- **No S3 bucket needed** — S3 was restricted/not desirable in the learner environment, and inline
  avoids it entirely.
- **No packaging/upload step** — the code ships *with* the template through the existing pipeline.
  Nothing extra to build, zip, or upload.
- **Deploys through the same CI/CD we already have** — no new workflow steps.
- **Perfect for small, dependency-free functions** — our handler is ~25 lines and uses only `boto3`,
  which is **already built into the Lambda Python runtime** (no `pip install` needed). So there are
  literally no dependencies to package.

**The limits of inline (why it's not always the answer):**
- Inline code has a **size cap** (~4 KB of code in the template). Fine for us, too small for real apps.
- **No third-party libraries** — you can't `pip install requests` and bundle it inline. Only the
  standard library + what's pre-baked in the runtime (boto3).
- Harder to unit-test (the code lives in YAML, not a `.py` file).

### Option B — S3-based — what "real" apps use
You zip the code (and any dependencies), upload the zip to an S3 bucket, and the template points at
`S3Bucket`/`S3Key`. This is the production pattern: supports large code, third-party libraries, and
proper local testing. The cost is more moving parts — an S3 bucket, a build/zip step, and an upload
step in the pipeline.

### The rule of thumb
> Inline = tiny, no-dependency, POC functions. S3 (or container images) = anything real with
> dependencies. We're a POC with a 25-line boto3-only handler, so inline is the right call. When the
> handler grows or needs libraries, graduate to S3.

---

## Least-privilege Lambda role

The Lambda runs *as* an IAM role (its "execution role"). We gave it only what it needs — nothing more:
- **SQS**: `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes` — to read and clear messages off
  the queue (the ESM needs these).
- **DynamoDB**: `PutItem` — to write rows. (Not delete, not scan — it only writes.)
- **CloudWatch Logs**: create/write its own log stream — so we get those `print` outputs.

Both the queue ARN and the table ARN are **imported** from the existing stacks (cross-stack
references), so the role is scoped to *exactly* this project's queue and table, not all queues/tables.

> Contrast with the deploy role, which has broad FullAccess (a known cleanup item). The Lambda role
> was built least-privilege from the start because it's a *runtime* role exposed to actual traffic.

---

## Cross-stack imports — how Lambda finds the queue and table

The Lambda stack doesn't hardcode the queue/table names. It **imports** them from the stacks that
own them, using the exports those stacks publish:
- `dc-status-sqs-fifo-dev-QueueArn` → the queue to read from
- `dc-status-dynamodb-dev-TableArn` → the table to write to (for the IAM permission)
- `dc-status-dynamodb-dev-TableName` → passed as the `TABLE_NAME` env var the code reads

This is why deploy order matters: SQS and DynamoDB must exist (and have exported these values) before
the Lambda stack deploys. The pipeline enforces this with
`needs: [deploy-sqs, deploy-dynamodb]`.

---

## The bug we hit: API Gateway role couldn't send to the dev queue

After the Lambda deployed green, the first live `POST /events` failed with:
```
dc-status-poc-apigw-role is not authorized to perform: sqs:SendMessage
on resource: dc-status-events-dev.fifo
```
**Cause:** the API Gateway role's send policy was scoped to `dc-status-*-poc.fifo` — a leftover from
when we planned a "poc" environment. But we deployed to **dev**, so the real queue is
`dc-status-events-dev.fifo`, which didn't match the `*-poc.fifo` pattern.

**Fix:** updated the role's inline policy to allow `sqs:SendMessage` on
`dc-status-events-*.fifo` (matches dev/qa/prod). IAM change, took effect in seconds, no redeploy.

> Lesson: naming pivots leave footprints. The role is *named* `-poc-` but serves dev — cosmetic, but
> its *policy* pattern actually mattered and had to be corrected. (Renaming the role to drop "poc" is
> a cleanup item.)

---

## Important: the async flow and the "3-second delay" myth

While testing, we waited ~3 seconds after each POST before scanning DynamoDB. **This is a testing
artifact, NOT a production characteristic.** Understanding why matters:

The system is **asynchronous and decoupled**:
```
Producer POSTs  →  API Gateway returns 200 immediately (message is now safely in SQS)  →  producer is done
                                          ↓  (independently, in the background)
                          SQS triggers the Lambda  →  Lambda writes to DynamoDB
```

The producer gets its response the instant the message reaches SQS. It does **not** wait for the
Lambda or the database. The processing happens separately, a moment later, with zero impact on the
producer.

The only reason *we* waited 3 seconds is that we were manually scanning the table right after posting,
and the background Lambda hadn't fired yet in that tiny window. In production:
- Nobody scans-immediately-after-posting.
- The queue **absorbs bursts** — if thousands of events arrive at once, they all land in SQS instantly
  and the producer is never slowed.
- The Lambda **drains the queue at its own pace**, scaling out automatically under load.

> **SQS is what *removes* the blockage, not what causes it.** Decoupling the producer from the
> consumer via a queue is precisely how you avoid making producers wait. There is no 3-second delay
> in prod — there's no waiting at all on the producer side.

---

## Test cases run (all passed)

All run live against `POST /events`, verified via DynamoDB scan + CloudWatch logs.

### Test 1 — Idempotency (same payload twice → no duplicate)
POST the identical `jira @ 10:00` payload again → count stays the same. Same pk+sk overwrites.
(Note: FIFO content-based dedup may also drop the duplicate at the *queue* level within the 5-min
dedup window — so sometimes the Lambda re-fires and overwrites, sometimes SQS dedupes before it ever
reaches the Lambda. Both correctly result in no duplicate row.)

### Test 2 — Second service (different pk → coexists)
POST `confluence @ 11:00` → new row alongside jira. Different partition key, both stored.

### Test 3 — Same service, new timestamp (history accumulates)
POST `jira @ 12:00` → jira now has TWO rows (10:00 and 12:00). Proves the time-series design:
same pk, different sk.

### Test 4 — Malformed JSON (graceful skip)
POST `this is not json at all` → log shows `Skipping unparseable record: <id>`, row count unchanged,
Lambda does NOT crash. Proves the try/except resilience.

### Test 5 — Missing required keys (graceful skip)
POST JSON missing `service_id` → log shows `Skipping record missing keys`, count unchanged. Proves
the second validation guard.

**Final verified state:** 3 rows — `jira@12:00` (operational), `confluence@11:00` (operational),
`jira@10:00` (degraded). Bad/incomplete messages skipped, never stored.

> **Note on the DLQ:** the handler *catches* bad messages and skips them (treats them as "handled"),
> so they do NOT go to the dead-letter queue — they're simply dropped with a log line. To actually
> exercise the DLQ, a message would have to make the Lambda *throw* repeatedly until `maxReceiveCount`
> (3) is hit. Current behavior is "skip-and-drop," which is a design choice — fine for a POC. For prod
> you might prefer "dead-letter bad messages for inspection" instead of silently dropping.

---

## Commands used / reference

### Send a test event (CloudShell — real curl)
```bash
curl -X POST "https://46ojhvo9p6.execute-api.us-east-1.amazonaws.com/v1/events" \
  -H "Content-Type: application/json" \
  -H "X-Message-Group-Id: jira" \
  -d '{"service_id":"jira","status":"degraded","checked_at":"2026-06-30T10:00:00Z"}'
```
> The `X-Message-Group-Id` header is REQUIRED — FIFO queues reject messages without a message group
> ID. (In PowerShell, `curl` is an alias for `Invoke-WebRequest` and doesn't accept `-H`/`-d`; use
> CloudShell, or `Invoke-RestMethod` with `-Headers`/`-Body`.)

### Check the table
```bash
aws dynamodb scan --table-name dc-status-dev --select COUNT          # just the count
aws dynamodb scan --table-name dc-status-dev --max-items 5           # see rows
aws dynamodb query --table-name dc-status-dev \
  --key-condition-expression "pk = :s" \
  --expression-attribute-values '{":s":{"S":"jira"}}'                # one service's history
```

### Watch the Lambda logs
```bash
aws logs tail /aws/lambda/dc-status-processor-dev --since 5m
```

### Confirm the cross-stack export names (before deploying lambda.yml)
```bash
aws cloudformation list-exports --query "Exports[?contains(Name, 'dc-status')].[Name,Value]" --output table
```

### Give the deploy role permission to create Lambdas (one-time, pre-deploy)
```bash
aws iam attach-role-policy --role-name dc-status-poc-deploy-role \
  --policy-arn arn:aws:iam::aws:policy/AWSLambda_FullAccess
```

### Fix the API Gateway role's SQS send permission (the dev-vs-poc naming bug)
```bash
cat > apigw-sqs-policy.json << 'EOF'
{ "Version":"2012-10-17","Statement":[{"Sid":"AllowSendToDcStatusQueues","Effect":"Allow",
  "Action":"sqs:SendMessage","Resource":"arn:aws:sqs:us-east-1:024111598068:dc-status-events-*.fifo"}]}
EOF
aws iam put-role-policy --role-name dc-status-poc-apigw-role \
  --policy-name dc-status-poc-apigw-sqs-send --policy-document file://apigw-sqs-policy.json
```

---

## Extensibility: using this for real observability (Splunk, heartbeats, alerting)

This architecture is *exactly* the standard pattern for ingesting observability signals. How real
use cases map onto what's already built:

### Splunk (or Prometheus, or any monitor) pushing "service down" events
This is just another **producer** calling `POST /events`. Splunk Synthetics detects a service is down
and POSTs `{"service_id":"payments-api","status":"down","checked_at":"..."}` — identical to our curl
test, just automated. **Works today, no infra change.**

### Regular heartbeats every 3-4 hours
Each heartbeat is a periodic POST: `{"service_id":"X","status":"operational","checked_at":"..."}`.
Every heartbeat becomes a new row (new `sk`, same `pk`), building the status history per service —
exactly what our two jira rows (10:00, 12:00) demonstrated. The newest `sk` for a service is its
current status. **Works today.**

### Firing an alert when something goes down
This is the one small addition — and the infrastructure for it is **already deployed**: the SNS FIFO
topic (the "fan-out" box in the diagram). The pattern:
- In the Processor Lambda, when `status == "down"`, **publish to the SNS topic**.
- Subscribe the SNS topic to an alert destination (email, Slack, PagerDuty, another Lambda).
- SNS fans out the alert.

This is an additive change (a few lines in the Lambda + an SNS subscription + `sns:Publish` on the
Lambda role) — **not new infrastructure**, since the topic already exists. ~1 hour of work.

### Why this scales for observability load
- **SQS absorbs bursts** — 50 services heartbeating at once = 50 messages queued instantly, no
  producer slowdown.
- **Lambda auto-scales** — more messages → more concurrent invocations, automatically.
- **DynamoDB is PAY_PER_REQUEST** — scales with traffic, no capacity planning.
- **FIFO ordering per service** — using `service_id` as the message group ID keeps each service's
  events in order, so a stale "operational" can't overwrite a newer "down."

### What you'd add for production-grade observability ingest
- The **down → SNS alert** wiring (small, topic already deployed).
- A **"current status" read pattern** — query newest `sk` per `pk`; the GSI1 index could serve
  "show all down services."
- **DLQ alarming** — a CloudWatch alarm on "messages in DLQ" = processing is failing.
- Possibly the **cache layer** (ElastiCache) if read volume gets high — but that's the read side, not
  ingest.

---

## State at end of Phase 5b
- ✅ Processor Lambda deployed via the OIDC pipeline (5th stack: `dc-status-lambda`).
- ✅ Event-source mapping live — SQS auto-triggers the Lambda.
- ✅ End-to-end verified: `POST /events` → SQS → Lambda → DynamoDB, with real rows in the table.
- ✅ Idempotency, multi-service, time-series history, and bad-message resilience all tested.
- ✅ Least-privilege Lambda execution role.
- ⬜ **Merge `rc-infra-draft` → main** (manager-gated) — the work is still on the draft branch.
- ⬜ Least-privilege cleanup of the *deploy* role + rename `dc-status-poc-*` roles to drop "poc".
- ⬜ (Optional/future) down-status → SNS alerting; Ingest Lambda; cache layer; the view app; promote
  to the real dev account.

## The one-line summary
> Built and deployed the consumer that connects the queue to the database. It's an event-driven,
> least-privilege Lambda shipped as inline code (no S3 needed for a tiny boto3-only handler), wired to
> SQS via an event-source mapping, importing the queue and table from the existing stacks. Verified
> live end-to-end. The system now ingests, processes, and stores status events — and is shaped exactly
> right to take Splunk alerts and heartbeats, with SNS-based alerting a small additive step away.