# 03 — Manual Deploy & End-to-End Test (my notes)

> Phase 3 deliverable for StatusPulse infra POC.
> Done in **CloudShell** (admin access needed to install the gh + aws CLI tooling).
> Outcome: full event-ingestion pipeline deployed and verified end to end.

---

## What I actually built

A **serverless event-ingestion pipeline** — no EC2, no backend server, no polling:

```
[Client / curl]                ← a "producer" (me, by hand, for now)
      │  POST /events  (JSON body + x-message-group-id header)
      ▼
[API Gateway HTTP API]         ← public ingestion endpoint
      │  assumes IAM role (statuspulse-dev-apigw-role)
      ▼
[SQS SendMessage API]          ← AWS_PROXY service integration, no Lambda
      ▼
[SQS FIFO main queue]          ← durable buffer, ordered, dedup
      │  after MaxReceiveCount failures
      ▼
[SQS FIFO DLQ]                 ← failed-message parking
      ⋮
[future consumer Lambda]  ❌ not built yet
      ▼
[DynamoDB table]          ⬜ empty until the consumer exists

(separately) [SNS FIFO topic] → fan-out to the SQS queue + future subscribers
```

Deploy order = dependency order: **dynamodb → sns → sqs-fifo → api-gateway**.

---

## Deploy order & commands (CloudShell)

All deploys use `aws cloudformation deploy` (create-or-update + change set handled for me),
`--capabilities CAPABILITY_NAMED_IAM` (templates touch named IAM), and
`--no-fail-on-empty-changeset` (don't error when nothing changed).

### 1. DynamoDB
```bash
aws cloudformation deploy \
  --stack-name statuspulse-dev-dynamodb \
  --template-file cloudformation/templates/dynamodb.yml \
  --parameter-overrides file://cloudformation/parameters/dev/dynamodb.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset
```

### 2. SNS  (exports TopicArn → needed by SQS)
```bash
aws cloudformation deploy \
  --stack-name statuspulse-dev-sns \
  --template-file cloudformation/templates/sns.yml \
  --parameter-overrides file://cloudformation/parameters/dev/sns.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# Grab the TopicArn to feed into the SQS param file
aws cloudformation describe-stacks \
  --stack-name statuspulse-dev-sns \
  --query "Stacks[0].Outputs"
```

### 3. SQS FIFO  (needs SnsTopicArn; exports MainQueueUrl → needed by API)
```bash
aws cloudformation deploy \
  --stack-name statuspulse-dev-sqs-fifo \
  --template-file cloudformation/templates/sqs-fifo.yml \
  --parameter-overrides file://cloudformation/parameters/dev/sqs-fifo.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset
```

### 4. API Gateway  (needs MainQueueUrl + ApiGatewayRoleArn)
```bash
aws cloudformation deploy \
  --stack-name statuspulse-dev-api \
  --template-file cloudformation/templates/api-gateway.yml \
  --parameter-overrides file://cloudformation/parameters/dev/api-gateway.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# Get the invoke URLs
aws cloudformation describe-stacks \
  --stack-name statuspulse-dev-api \
  --query "Stacks[0].Outputs"
```

---

## Errors I hit and what fixed them (real debugging log)

| Error | Cause | Fix |
|---|---|---|
| `Fn::Equals cannot be partially collapsed` (sqs) | a boolean property was fed an `!Equals` where CFN needed a literal | pulled the repo patch that corrected it |
| api stack `ROLLBACK_COMPLETE`, integration DELETE in events | `IntegrationType: AWS`/`MOCK` + VTL templates — REST-API syntax on an **HTTP** API | switch to `AWS_PROXY` + `IntegrationSubtype: SQS-SendMessage` + `RequestParameters`; drop MOCK `/health` |
| `Stack ... is in ROLLBACK_COMPLETE state and can not be updated` | a failed **create** can't be updated | `delete-stack` → `wait stack-delete-complete` → redeploy |
| `POST /events` 403 / AccessDenied (would have hit) | role lacked `sqs:SendMessage` | attach SQS send permission to the role |
| `curl: Could not resolve host: https` | typo'd URL `https://https://...` and `https://http://...` | use the URL exactly once, with one scheme |

---

## The IAM role (the crux of the API → SQS step)

API Gateway can't call SQS on its own — it **assumes a role** and uses that role's permissions.
Two halves must both be correct:

**Trust policy** (who may assume it):
```json
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Principal": { "Service": "apigateway.amazonaws.com" },
      "Action": "sts:AssumeRole" } ] }
```

**Permissions policy** (what it may do) — least privilege, ONE action on ONE queue:
```json
{ "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowSendToStatusPulseQueue",
      "Effect": "Allow",
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-east-1:024111598068:statuspulse-events-dev.fifo" } ] }
```

Apply the scoped policy:
```bash
aws iam put-role-policy \
  --role-name statuspulse-dev-apigw-role \
  --policy-name statuspulse-dev-apigw-sqs-send \
  --policy-document '{ "Version":"2012-10-17","Statement":[
    {"Sid":"AllowSendToStatusPulseQueue","Effect":"Allow",
     "Action":"sqs:SendMessage",
     "Resource":"arn:aws:sqs:us-east-1:024111598068:statuspulse-events-dev.fifo"}]}'
```

> ⚠️ What I did to unblock vs what's correct: to get past AccessDenied I attached the AWS-managed
> `AmazonSQSFullAccess` and `AmazonSNSFullAccess`. **That's over-privileged** — see "Too much access"
> below. Phase 5 hardening = remove both managed policies and keep only the scoped inline policy above.

---

## "What happens if too much access is given?" (important learning)

My role only needs `sqs:SendMessage` on one queue. I gave it `AmazonSQSFullAccess` +
`AmazonSNSFullAccess` (every SQS/SNS action on every queue/topic in the account). Why that's bad:

- **Blast radius.** If this role leaks or is abused, the damage is bounded by what it *can* do. Scoped
  = "spam one queue, worst case." FullAccess = "delete/drain every queue, publish to/delete every topic."
- **Confused deputy.** API Gateway acts on behalf of callers; a powerful role is a bigger lever for a
  crafted request to misuse.
- **Audit/clarity.** A scoped policy documents intent ("sends to the events queue, period"). FullAccess
  tells a reviewer nothing and gets flagged by IAM Access Analyzer.
- **Hides bugs.** A wrong queue ARN fails loudly under a scoped policy (AccessDenied) so I'd catch it;
  FullAccess silently allows everything and the misconfig surfaces later.

AWS's own guidance: managed policies are fine to *get started*, but they don't grant least privilege;
the secure end state is a custom policy with only the permissions needed, ideally refined from real
usage via Access Analyzer. Standard pattern = start broad, then shrink. So this is the normal arc; I
just need to finish the "shrink" step.

---

## End-to-end test

### GET /health → `{"message":"Not Found"}`  ✅ expected
I removed the `/health` route (HTTP APIs can't do MOCK). So a 404 here is correct — there is simply no
such route. (If I want a real health check later: a tiny Lambda behind `GET /health`.)

URL gotcha I tripped on: it's `https://<id>.execute-api...`, used **once**. `https://https://...` and
`https://http://...` both fail with `Could not resolve host`.

### POST /events → SQS  ✅ works
```bash
curl -X POST https://lb7nq7lsz2.execute-api.us-east-1.amazonaws.com/dev/events \
  -H "Content-Type: application/json" \
  -H "x-message-group-id: test-group" \
  -d '{"service_id":"jira","status":"degraded","checked_at":"2026-06-27T10:00:00Z"}'
```
Response (raw SQS XML, passed straight through by AWS_PROXY):
```xml
<SendMessageResponse>
  <SendMessageResult>
    <MessageId>00ae6dc3-0737-4c22-aaec-a8747bac0dbe</MessageId>
    <MD5OfMessageBody>40aabda8a07d67958814a03995e3e166</MD5OfMessageBody>
    <SequenceNumber>18903082326332655616</SequenceNumber>
  </SendMessageResult>
</SendMessageResponse>
```
- `MessageId` = the message now stored in SQS.
- `SequenceNumber` = FIFO ordering token.
- XML (not JSON) because SQS's API returns XML and AWS_PROXY relays the service response verbatim.
  Turning it into JSON would need a response mapping — a possible Phase 5 nicety, not needed now.

### Verify in the queue  ✅
SQS console → `statuspulse-events-dev.fifo` → Send and receive messages → Poll. The received message
body is exactly the JSON I sent (`service_id: jira, status: degraded, checked_at: ...`), 77 bytes,
receive count 1. Confirmed.

---

## "Explain how this jira-degraded came / DB empty / how did degrade happen?"

- **Nothing real happened.** `-d '{...}'` is the request body I typed by hand. There is no real Jira,
  no monitor, no actual outage. I authored a **synthetic event** and POSTed it. The pipeline just
  carried my claim faithfully: curl → API GW → SQS.
- In the real design, an automated **producer** (a health-checker hitting real services on a schedule)
  would generate this exact JSON shape when it detects a problem and POST it to `/events`. I'm standing
  in for that producer with curl. The system can't tell the difference — it just sees a valid event.
- **DynamoDB is empty** because nothing reads from SQS yet. The message that moves data SQS→DynamoDB
  is the **consumer Lambda**, which doesn't exist. The message sits in the queue until consumed/expired.
  Empty table = correct current state, not a bug.

---

## Message shape (the contract flowing through the pipe)
```json
{ "service_id": "jira", "status": "degraded", "checked_at": "2026-06-27T10:00:00Z" }
```
- `service_id` — which service the report is about.
- `status` — its reported state (e.g. operational / degraded / down).
- `checked_at` — when the check happened (ISO-8601).
This is what a future consumer would parse and write into DynamoDB (likely `pk = service_id`,
`sk = checked_at`, matching the table's pk/sk).

---

## Phase 3 done — checklist
- ✅ CloudFormation IaC, deployed via CLI
- ✅ Multi-stack dependency wiring (exports/params in deploy order)
- ✅ API Gateway → SQS direct integration (no Lambda)
- ✅ FIFO constraints understood (MessageGroupId required)
- ✅ IAM role assume + permissions working
- ✅ End-to-end test verified (message visible in queue)
- ⬜ Tighten role to least privilege (Phase 5)
- ⬜ Build consumer to populate DynamoDB (future)

## Open questions → Phase 4
- Replace the over-broad role policies with the scoped inline one and re-test.
- Phase 4: wire GitHub Actions + OIDC so these deploys run in CI instead of CloudShell.
- Decide whether `/health` is worth a small Lambda or stays dropped.
```