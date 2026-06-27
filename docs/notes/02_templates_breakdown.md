# Template Walkthroughs (my notes)

> Phase 2 deliverable for StatusPulse infra POC.
> Goal: explain the whole system without opening VS Code.
> Deploy order = dependency order: dynamodb → sns → sqs-fifo → api-gateway.

Refer to:
https://docs.amazonaws.cn/en_us/AWSCloudFormation/latest/UserGuide/template-guide.html
https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/GettingStarted.html

---

## The system in one picture

```
                       (future consumer Lambda)
                                 │ reads
                                 ▼
Client ──POST /events──► API Gateway (HTTP API) ──SendMessage──► SQS FIFO main queue ──► DynamoDB
                  │                                                     │ after N failures
                  └──GET /health──► MOCK (static 200)                   ▼
                                                                  SQS FIFO DLQ

        SNS FIFO topic ──fan-out──► (subscribes) SQS FIFO main queue
        (optional alerting / extra subscribers hang off SNS)
```

Two ways messages reach the queue:
1. **Synchronous ingest:** Client → API Gateway `POST /events` → **directly** SendMessage to SQS (no Lambda).
2. **Fan-out:** anything that publishes to the **SNS** topic → SNS pushes to the subscribed SQS queue.

DynamoDB is the durable store the (future) consumer writes into after reading from SQS.

---

## How the four stacks wire together (the part that matters most)

These are **four separate stacks**, deployed in order, coupled by **Outputs/Exports** and **passed parameters**:

| Producer stack | Exports | Consumed by | How |
|---|---|---|---|
| sns.yml | `TopicArn` | sqs-fifo.yml | passed in as the `SnsTopicArn` **parameter** |
| sqs-fifo.yml | `MainQueueUrl`, `MainQueueArn` | api-gateway.yml | passed in as `MainQueueUrl` / `MainQueueArn` **parameters** |
| dynamodb.yml | `TableName`, `TableArn` | future consumer | not wired yet (consumer doesn't exist) |

Important nuance: the repo passes ARNs as **plain `String` parameters**, not via `!ImportValue`.
That means coupling is *manual* — when I deploy in Phase 3 I must copy the SNS topic ARN into the
SQS deploy command, and the SQS URL/ARN into the API deploy command. Looser than ImportValue
(no hard delete-lock between stacks) but it's on me to pass the right values. Noting this for Phase 3.

---

## dynamodb.yml

**Purpose:** a single DynamoDB table using the single-table design pattern — one table serves many
access patterns via a composite primary key plus one GSI.

### Parameters
| Parameter | Meaning |
|---|---|
| `TableName` | Physical table name (3–255 chars). |
| `BillingMode` | `PAY_PER_REQUEST` (on-demand, pay per request, no capacity planning) or `PROVISIONED`. |
| `PointInTimeRecoveryEnabled` | PITR = continuous backups, restore to any second in last 35 days. |
| `DeletionProtection` | Blocks deletion of the table by anyone/anything until turned off. |
| `TTLAttributeName` | Which attribute holds the expiry timestamp (default `ttl`). |

### How the table is actually created (top → bottom)

`Type: AWS::DynamoDB::Table` tells CloudFormation to call the DynamoDB `CreateTable` API. The
properties translate as follows:

- **`DeletionPolicy: Retain`** (this sits *outside* Properties, on the resource itself): if the
  **stack** is deleted, the **table is kept**, not destroyed. This is a stack-level safety net,
  separate from `DeletionProtectionEnabled` (which blocks deletion by *any* path). Together they
  mean: deleting the stack leaves your data; nothing deletes the table by accident. Good for a store.

- **`AttributeDefinitions`** — you only list attributes that are used as **keys** (table key or any
  index key). DynamoDB is schemaless for everything else; you do NOT declare normal item fields here.
  Here: `pk`, `sk`, `gsi1pk`, `gsi1sk`, all type `S` (string). That's why there are exactly four —
  two for the primary key, two for the GSI.

- **`KeySchema`** — defines the **primary key**:
  - `pk` = `HASH` (partition key) — determines which physical partition an item lives in.
  - `sk` = `RANGE` (sort key) — orders items within a partition, enables range queries.
  - Composite key (HASH+RANGE) means you can store many related items under one `pk` and query/sort
    them by `sk`. This is the foundation of single-table design.

- **`GlobalSecondaryIndexes`** — `GSI1` with `gsi1pk`(HASH) + `gsi1sk`(RANGE) and
  `Projection: ALL` (the index copies *all* attributes, so queries on the index don't need a second
  lookup to the base table — costs more storage, simpler queries). A GSI is essentially an
  alternate "view" of the table that lets you query by a *different* key than the primary key
  (e.g. query by status, by time window, by entity-type) instead of only by `pk`.

- **`TimeToLiveSpecification`** — DynamoDB auto-deletes items whose `ttl` attribute (a Unix epoch
  timestamp) is in the past. Free housekeeping; deletes happen within ~48h of expiry, not instantly.

- **`PointInTimeRecoverySpecification`** — turns on continuous backups when the param is `true`.

- **`Tags`** — metadata (ManagedBy, Project). No functional effect; used for cost tracking/filtering.

### Conditions
- `IsPitrEnabled` / `IsDeletionProtected` convert the `"true"`/`"false"` *string* params into real
  booleans via `!If`. (Params are strings here; the `!If` is what feeds an actual boolean to AWS.)

### Outputs
- `TableName` (`!Ref` → physical name) and `TableArn` (`!GetAtt ...Arn`). Both **exported** so a
  future consumer/Lambda stack can import them. Your `!Ref` vs `!GetAtt` understanding is correct:
  `!Ref` on the table returns its name; the ARN needs `!GetAtt`.

### Risk areas (what BREAKS)
- **`TableName` change → REPLACEMENT.** CloudFormation deletes and recreates the table → **all data
  gone** (and a new physical table). BUT because `DeletionPolicy: Retain` is set, the *old* table is
  retained rather than deleted — so you'd end up with an orphaned old table AND a new empty one, and
  a name clash if the name is reused. Either way: never rename casually.
- **`KeySchema` change → REPLACEMENT.** The primary key is immutable. Changing pk/sk = new table.
- **GSI changes are special:** DynamoDB only allows **one GSI add/delete per update** (because adding
  a GSI triggers a full-table *backfill* scan). Trying to add/remove two GSIs in a single stack
  update fails with "Cannot perform more than one GSI creation or deletion in a single update." Plan
  GSI changes one at a time. (Creating a brand-new table with multiple GSIs at once is fine — the
  limit is only on *updates*.)
- **TTL attribute rename** is fine (no replacement), but items already written with the old field
  name won't expire.

> First real production insight (my own words): the table's *identity* (name + primary key) is
> frozen at creation. Everything that defines "what this table IS" forces a destroy-and-recreate.
> Everything that's a *setting* (PITR, deletion protection, TTL, tags) can change in place.

---

## sns.yml

**Purpose:** a **FIFO SNS topic** (ordered, exactly-once-ish publish/subscribe fan-out) with a
resource policy controlling who can publish, plus an *optional* single subscription created at
deploy time.

### Parameters
| Parameter | Meaning |
|---|---|
| `TopicBaseName` | Base name; the template appends env + `.fifo`. |
| `EnvironmentName` | `dev`/`qa`/`prod` — constrained by AllowedValues. |
| `KmsMasterKeyId` | Optional KMS key for encryption; blank = AWS-managed key. |
| `InitialSubscriptionProtocol` / `...Endpoint` | Optional one-shot subscription (e.g. email alert). |

### Conditions
- `HasKmsKey` = key param not empty. `HasInitialSubscription` = endpoint not empty.
- These drive optional behaviour: only attach KMS / create a subscription if values were supplied.

### Resources (top → bottom)
- **`StatusPulseTopic` (`AWS::SNS::Topic`)**:
  - `TopicName: ${base}-${env}.fifo` — **FIFO topics MUST end in `.fifo`**. This is a hard AWS rule.
  - `FifoTopic: true` — ordered delivery + deduplication. Trade-off: FIFO has lower throughput than
    standard SNS, but guarantees order.
  - `ContentBasedDeduplication: true` — SNS computes the dedup ID from a SHA-256 of the message body,
    so publishers don't have to send a `MessageDeduplicationId` themselves. Two identical bodies
    within the 5-minute dedup window count as one.
  - `KmsMasterKeyId: !If [HasKmsKey, !Ref KmsMasterKeyId, !Ref AWS::NoValue]` — the `AWS::NoValue`
    trick: if no key, the property is **omitted entirely** (not set to empty), so SNS falls back to
    its default. This is the clean way to make a property conditional.

- **`StatusPulseTopicPolicy` (`AWS::SNS::TopicPolicy`)** — a **resource-based policy** on the topic:
  - `AllowAccountPublish`: principals in this account (`...:root`) can `sns:Publish`.
  - `AllowSNSToSQS`: the `sns.amazonaws.com` service principal can publish. (Note: this statement is
    a bit loose — see Risk areas.)

- **`InitialSubscription` (`AWS::SNS::Subscription`)** — only created when `HasInitialSubscription`.
  `RawMessageDelivery` is set to `!Equals [protocol, sqs]`, i.e. raw delivery on for SQS subs so the
  consumer gets the bare body without SNS's JSON envelope wrapper.

### Outputs
- `TopicArn` (`!Ref` topic) and `TopicName` (`!GetAtt ...TopicName`), both exported.
- **`TopicArn` is the key handoff** — sqs-fifo.yml takes it as its `SnsTopicArn` parameter.

### Risk areas (what BREAKS)
- **`TopicName` change → REPLACEMENT** (new topic, all existing subscriptions lost). And since name
  encodes env, changing env = new topic.
- **`FifoTopic` cannot be toggled** after creation → replacement. FIFO-ness is fixed at birth.
- The `AllowSNSToSQS` statement allows *any* SNS service call to publish without an `aws:SourceArn`
  condition scoping it to a specific topic — broader than ideal. (Compare with the SQS queue policy,
  which DOES scope by SourceArn. Candidate Phase 5 hardening.)
- A `.fifo` topic can only deliver to `.fifo` queues — the SQS side must also be FIFO (it is).

---

## sqs-fifo.yml

**Purpose:** the buffering/reliability layer — a FIFO main queue + a FIFO dead-letter queue, a queue
policy letting SNS send to it, and the subscription that actually wires SNS → SQS.
Most important template after DynamoDB.

### Parameters
| Parameter | Meaning |
|---|---|
| `QueueBaseName` / `EnvironmentName` | Naming, same pattern as SNS. |
| `SnsTopicArn` | **The ARN exported by sns.yml** — this is the cross-stack link. |
| `VisibilityTimeoutSeconds` | How long a received message is hidden from other consumers (0–43200). Must be ≥ max processing time. |
| `MaxReceiveCount` | After this many failed receives, the message goes to the DLQ (1–1000). |
| `ContentBasedDeduplication` | `"true"`/`"false"` string → drives dedup on both queues. |

### Resources (top → bottom)
- **`StatusPulseDlq` (`AWS::SQS::Queue`)** — the dead-letter queue, created **first** because the
  main queue references it:
  - `.fifo` name, `FifoQueue: true`.
  - `ContentBasedDeduplication: !Equals [param, "true"]` — converts the string param to a boolean.
  - `MessageRetentionPeriod: 1209600` = 14 days (the max) — keep failed messages long enough to
    investigate.
  - A DLQ is just a normal queue that *receives* messages that failed processing too many times.

- **`StatusPulseQueue` (`AWS::SQS::Queue`)** — the main queue:
  - FIFO, content-based dedup, `VisibilityTimeout` from param.
  - **`RedrivePolicy`** — the heart of reliability:
    - `deadLetterTargetArn: !GetAtt StatusPulseDlq.Arn` — where failed messages go.
    - `maxReceiveCount: !Ref MaxReceiveCount` — how many delivery attempts before redirect.
    - Flow: consumer receives a message → message becomes invisible for `VisibilityTimeout` → if the
      consumer doesn't delete it in time (i.e. it failed/crashed), it becomes visible again and the
      receive count increments → after `maxReceiveCount` failures, SQS moves it to the DLQ instead
      of redelivering forever. This is the **automatic poison-message handling**.
  - This is also an **implicit dependency**: the `!GetAtt StatusPulseDlq.Arn` reference is why
    CloudFormation creates the DLQ before the main queue, with no `DependsOn` needed.

- **`StatusPulseQueuePolicy` (`AWS::SQS::QueuePolicy`)** — resource policy on the main queue:
  - Allows the `sns.amazonaws.com` service principal to `sqs:SendMessage`...
  - ...**scoped** by `Condition: ArnEquals aws:SourceArn = SnsTopicArn`. So *only* this specific SNS
    topic can push to the queue. This is the correctly-scoped version (contrast the SNS policy above).
  - Without this policy, SNS would be denied when it tries to deliver — SQS resource policies are how
    cross-service sends are authorized.

- **`SnsToQueueSubscription` (`AWS::SNS::Subscription`)** — the actual wire:
  - `TopicArn: SnsTopicArn`, `Protocol: sqs`, `Endpoint: !GetAtt StatusPulseQueue.Arn`.
  - `RawMessageDelivery: true` — consumer reads the raw body, no SNS envelope.
  - This is what makes the **fan-out** real: publish once to SNS, it lands in this queue (and any
    other subscribers you add later).

### Outputs
- `MainQueueUrl` (`!Ref` queue → URL), `MainQueueArn` (`!GetAtt ...Arn`), plus `DlqUrl`/`DlqArn`.
- `!Ref` on an SQS queue returns the **queue URL** (that's the type-specific Ref behaviour); the ARN
  needs `!GetAtt`. **MainQueueUrl + MainQueueArn are the handoff to api-gateway.yml.**

### CRITICAL QUESTION — why both SNS *and* SQS?
- **SNS** = fan-out + decoupling. One publish → many independent subscribers (queue, email, future
  Lambda, another team's queue). Publisher doesn't know or care who's listening.
- **SQS** = buffering + retry + ordering. Messages wait durably until a consumer is ready; failed
  messages get retried and eventually parked in a DLQ; FIFO preserves order.
- **Together** = scalable *and* reliable: SNS spreads the event to whoever needs it; SQS makes sure
  each consumer can process at its own pace without losing or duplicating messages, with a safety net
  for failures. This is the classic **SNS→SQS fan-out** pattern.

### Risk areas (what BREAKS)
- **Queue name change → REPLACEMENT** (new queue; in-flight messages lost).
- **`FifoQueue` is immutable** → replacement if toggled.
- **`VisibilityTimeout` too low** → a slow consumer's message reappears mid-processing and gets
  processed twice (or wrongly counted toward `maxReceiveCount` and dead-lettered prematurely). Not a
  CFN error — a *runtime* bug. Set it ≥ worst-case processing time.
- **DLQ and main queue must both be FIFO** (or both standard). Mixing types is rejected.
- **`SnsTopicArn` wrong/stale** → subscription points at nothing; messages silently never arrive.

---

## api-gateway.yml

**Purpose:** the entry point — an **HTTP API (API Gateway v2)** with two routes. `GET /health`
returns a static 200 via a MOCK integration; `POST /events` writes **directly to SQS** using an AWS
service integration and an IAM role (no Lambda in the path).

### Parameters
| Parameter | Meaning |
|---|---|
| `ApiBaseName` / `StageName` | API display name; stage = deployed environment (e.g. `v1`). |
| `ThrottlingBurstLimit` / `ThrottlingRateLimit` | Burst (max concurrent) and steady-state req/sec caps. |
| `CorsAllowOrigins` | Comma-separated origins (or `*`) browsers may call from. |
| `MainQueueUrl` / `MainQueueArn` | From sqs-fifo.yml — the integration target. |
| `ApiGatewayRoleArn` | IAM role API Gateway assumes to call SQS (needs `sqs:SendMessage` on the queue). |

### Resources (top → bottom)
- **`StatusPulseHttpApi` (`AWS::ApiGatewayV2::Api`)** — `ProtocolType: HTTP` = the cheaper, lower-
  latency **HTTP API** (vs the older, more feature-rich REST API). `CorsConfiguration` lets browsers
  call it directly (allowed methods/origins/headers, `MaxAge` caches the preflight 300s).
  `AllowOrigins: !Split [",", ...]` turns the comma-string param into a list.

- **GET /health (three resources working together):**
  - `HealthIntegration` (`IntegrationType: MOCK`) — returns a canned response without calling any
    backend. Pure health check; costs nothing downstream.
  - `HealthRoute` — maps `RouteKey: "GET /health"` to that integration via
    `Target: integrations/${HealthIntegration}`.
  - `HealthIntegrationResponse` / `HealthRouteResponse` — shape the static `{"status":"ok"}` 200.

- **POST /events (the real ingest path):**
  - `EventsIntegration` (`IntegrationType: AWS_PROXY`, `IntegrationSubtype: SQS-SendMessage`) — a
    **direct AWS service integration**: API Gateway itself calls the SQS `SendMessage` API. No Lambda.
    - `CredentialsArn: ApiGatewayRoleArn` — the IAM role API GW assumes to be *allowed* to send.
    - `RequestParameters` maps the incoming HTTP request to SendMessage args:
      - `QueueUrl: MainQueueUrl`
      - `MessageBody: "$request.body"` — the raw HTTP body becomes the queue message.
      - `MessageGroupId: "$request.header.x-message-group-id"` — **FIFO requires a MessageGroupId**;
        here it's pulled from a request header (see Risk areas — this is fragile).
  - `EventsRoute` — maps `RouteKey: "POST /events"` to the integration.

- **`StatusPulseStage` (`AWS::ApiGatewayV2::Stage`)** — the deployable stage:
  - `AutoDeploy: true` — route/integration changes go live automatically (no manual deployment step).
  - `DefaultRouteSettings` applies the throttling burst/rate caps.

### Outputs
- `HttpApiId` and **`InvokeUrl`** (built with `!Sub` from the API id + region + stage). `InvokeUrl`
  is what you curl in Phase 3 (`/health` and `/events`).

### CRITICAL QUESTION — why remove the ingest Lambda?
- **Simpler & cheaper:** API Gateway → SQS directly = one fewer service, no Lambda cold starts, no
  Lambda cost, lower latency.
- **Trade-off:** you lose the place where a Lambda would **validate / normalize / enrich** the
  payload before it hits the queue. Whatever the client POSTs goes in raw. For a POC that's fine; for
  production you'd reintroduce a Lambda (or use API GW request validation/mapping) if you need schema
  enforcement.

### Risk areas (what BREAKS)
- **`MessageGroupId` from a header** — if the client doesn't send `x-message-group-id`, the value is
  empty and SQS **rejects** the SendMessage (FIFO requires a non-empty group id). The mock comment in
  the file even says "default to default" but the code doesn't actually default it. **This is the most
  likely thing to break when you test `POST /events` in Phase 3.** Likely fix: a request mapping that
  supplies a fallback, or require the header.
- **`ApiGatewayRoleArn` lacks `sqs:SendMessage`** on the queue → 403/AccessDenied at runtime.
- **`MainQueueUrl`/`MainQueueArn` stale** (wrong stack copied in) → sends fail or go to the wrong queue.
- **No dedup id on POST** — relies on the queue's `ContentBasedDeduplication`; identical bodies within
  5 min collapse to one message. Fine if intended, surprising if not.
- **CORS `*` with credentials** is permissive — acceptable for POC, tighten for prod.

---

## Phase 2 self-test (can I explain it cold?)
> Client hits **API Gateway**. `GET /health` returns a static 200 (MOCK). `POST /events` makes API
> Gateway call **SQS SendMessage directly** (IAM role, no Lambda) into a **FIFO main queue**. A
> **future consumer** reads the queue and writes to **DynamoDB** (single-table: pk/sk + GSI1). Failed
> messages retry up to `maxReceiveCount`, then land in the **FIFO DLQ**. Separately, **SNS** provides
> **fan-out**: publish once, SNS delivers to the subscribed SQS queue (and any future subscribers),
> with a queue policy authorizing SNS and scoped to the one topic. Stacks are wired by passing
> exported ARNs/URLs as parameters in deploy order: DynamoDB → SNS → SQS → API.

## Open questions carried into Phase 3
- Does `POST /events` actually succeed without an `x-message-group-id` header? (I predict: no.)
- Are ARNs wired via `!ImportValue` or manual param passing? (Looks manual — confirm in deploy scripts.)
- Is the `ApiGatewayRoleArn` role defined in another template I haven't seen, or created by hand?
- Does the SNS→SQS path and the API→SQS path write the *same* message shape into the queue?
```