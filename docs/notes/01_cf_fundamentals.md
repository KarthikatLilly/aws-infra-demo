# CloudFormation Fundamentals (my notes)

> Phase 1 deliverable for the StatusPulse infra POC.
> Source material: LinkedIn Learning "Introduction to CloudFormation" + AWS docs
> (GettingStarted + template-guide). These notes go past the course — they capture
> the *why* and the gotchas, not just the *what*.

---

## 1. Stack vs Template (the core mental model)

- **Template** = the source file (YAML or JSON). It is a *declaration of desired state*.
  It describes *what* you want to exist, not *how* to build it. It is inert — it does nothing on its own.
- **Stack** = a deployed, living instance of a template. CloudFormation reads the template,
  figures out the order to create things, calls the underlying AWS APIs, and tracks every
  resource it created as a single managed unit.
- One template can produce **many stacks** (e.g. `DevBucketStack` and `ProdBucketStack` from
  the same bucket template — exactly the challenge I solved). Each stack is independent state.
- **Why this matters:** the stack is the unit of lifecycle. Delete the stack → CloudFormation
  deletes everything it made (subject to DeletionPolicy). This is the create-and-tear-down
  lifecycle I watched on `BasicStack` (CREATE_IN_PROGRESS → running t3.micro → DELETE_IN_PROGRESS).

**Analogy:** template is a class, stack is an object/instance. Same code, many instances, each with own state.

---

## 2. Template sections I care about

Only **`Resources`** is mandatory. Everything else is optional structure. The eight sections:

| Section | Mandatory? | What it's for | Do I need it now? |
|---|---|---|---|
| `AWSTemplateFormatVersion` | No | Pins the template language version (only valid value: `2010-09-09`) | Nice-to-have, harmless |
| `Description` | No | Free-text string shown in the console | Yes, for docs |
| `Parameters` | No | Inputs supplied at deploy time | **Yes** |
| `Metadata` | No | Extra data about the template (e.g. console UI grouping) | Not yet |
| `Mappings` | No | Static lookup tables (key → value), e.g. region → AMI | Not yet |
| `Conditions` | No | Boolean logic to include/exclude resources | Soon (dev vs prod) |
| `Transform` | No | Macros — most commonly `AWS::Serverless` (SAM) | Not yet |
| `Resources` | **YES** | The actual AWS things to create | **Yes** |
| `Outputs` | No | Values to expose after deploy | **Yes** |

The four I'll actually write in StatusPulse: **Parameters, Resources, Outputs, Conditions.**
Mappings I understand but don't need yet.

### Resources — the anatomy of one resource
```yaml
Resources:
  MyInstance:                          # Logical ID (my name, unique within template)
    Type: AWS::EC2::Instance           # Resource type: AWS::<service>::<thing>
    Properties:                        # Config for that resource type
      ImageId: !Ref MyImageId
      InstanceType: !Ref MyInstanceType
```
- **Logical ID**: how *I* refer to the resource inside the template (`!Ref MyInstance`).
- **Physical ID**: the real ID AWS assigns after creation (`i-0ad5738...`). I don't pick this.
- Best practice from the course: distinct, meaningful logical IDs; split templates by tier
  (web / networking / database).

### Parameters — making templates reusable
```yaml
Parameters:
  MyInstanceType:
    Type: String
    Default: t3.micro
    AllowedValues: [t3.micro, t3.small, t3.medium, t3.large]  # renders as a dropdown
    Description: EC2 size for the web tier
```
- `Default` → optional value if none supplied.
- `AllowedValues` → constrains input (the dropdown I saw).
- Other useful constraints not in the course: `AllowedPattern` (regex), `MinLength`/`MaxLength`,
  `MinValue`/`MaxValue`, `NoEcho: true` (masks secrets in console/logs).
- Special parameter types worth knowing: `AWS::EC2::KeyPair::KeyName`,
  `AWS::EC2::Image::Id`, `AWS::SSM::Parameter::Value<String>` — these validate against your
  account and give nicer console pickers.

### Outputs — exposing values
```yaml
Outputs:
  PublicIP:
    Description: Public IP of the web server
    Value: !GetAtt MyInstance.PublicIp
  BucketArn:
    Value: !GetAtt MyS3.Arn
    Export:                            # <-- makes it importable by OTHER stacks
      Name: statuspulse-bucket-arn
```
- Outputs surface data (ARNs, IPs, domain names) — what I saw in the Outputs tab.
- **`Export`** is the part the course glossed: an exported output can be pulled into another
  stack with `!ImportValue statuspulse-bucket-arn`. This is how you wire separate stacks
  together (e.g. networking stack exports VPC ID, app stack imports it). Export names must be
  unique per region, and you **cannot delete/modify an export while another stack imports it.**

---

## 3. Intrinsic functions

Functions CloudFormation evaluates at deploy time. The three I'll use constantly:

### `!Ref`
- Returns the *default attribute* of whatever you point at.
- On a **parameter** → returns the parameter's value.
- On a **resource** → returns its physical ID (e.g. instance ID, bucket name — varies by type).
- Example: `ImageId: !Ref MyImageId` and `SecurityGroupIds: [!Ref MySecurityGroup]`.

### `!GetAtt`
- Returns a *specific named attribute* via dot notation. Use when `!Ref` doesn't give what you need.
- `!GetAtt MyInstance.PublicIp`, `!GetAtt MyS3.Arn`, `!GetAtt MyLB.DNSName`.
- **Rule of thumb:** if you want "the IP / ARN / DNS name / a non-default property" → `!GetAtt`.
  If you want "the main ID of this thing" → `!Ref`. Check the resource's docs page; each type
  lists exactly what `Ref` returns and what `GetAtt` attributes exist.

### `!Sub`
- String interpolation. Inject parameter values, resource refs, and pseudo-params into a string.
```yaml
BucketName: !Sub "${Environment}-statuspulse-${AWS::AccountId}"
UserData: !Sub |
  #!/bin/bash
  echo "Region is ${AWS::Region}"
```
- `${AWS::Region}`, `${AWS::AccountId}`, `${AWS::StackName}` are **pseudo-parameters** —
  values AWS provides automatically, no need to declare them.
- `!Sub` is cleaner than the old `!Join` approach for building strings.

### Others I should recognise (not memorise yet)
- `!Join [delimiter, [list]]` — glue a list into a string.
- `!Select [index, [list]]` — pick one item.
- `!GetAZs` — list of availability zones in the region.
- `!FindInMap [MapName, TopKey, SecondKey]` — read from `Mappings`.
- `!If`, `!Equals`, `!And`, `!Or`, `!Not` — used with `Conditions`.

> YAML gotcha: the short form `!GetAtt` and the function form `Fn::GetAtt` are the same thing.
> You can't nest two short-form functions directly in some cases (e.g. `!Sub` inside `!Ref`);
> when in doubt use the full `Fn::` form for the outer one.

---

## 4. Conditions (will need for dev vs prod)

```yaml
Parameters:
  Environment:
    Type: String
    AllowedValues: [dev, prod]
Conditions:
  IsProd: !Equals [!Ref Environment, prod]
Resources:
  ProdOnlyAlarm:
    Type: AWS::CloudWatch::Alarm
    Condition: IsProd        # only created when IsProd is true
    Properties: ...
```
- Define a named boolean in `Conditions`, attach it to a resource (or output) with `Condition:`.
- Lets one template serve both environments — turn on versioning/alarms/bigger instances in prod only.

---

## 5. Change sets

- A **change set** is a *preview/diff* of what an update would do **before** CloudFormation touches anything.
- Workflow: edit template → create change set → review → execute (or discard).
- The console preview I saw showed actions: **Add / Modify / Remove**, plus a critical column:
  **Replacement** = `True` / `False` / `Conditional`.
  - `Replacement: True` → the resource gets **destroyed and recreated** (new physical ID,
    downtime, IP changes). This is the dangerous one. My change set showed `Conditional` on
    MyInstance/MyEIPAssociation — meaning *it depends on which property changed*.
- **Why I care:** some property edits are in-place updates, others force replacement. Change sets
  stop me from accidentally deleting a database because I changed one innocent-looking field.
- CLI: `create-change-set` → `describe-change-set` (review) → `execute-change-set`.

---

## 6. CAPABILITY_NAMED_IAM (and friends)

When a template can affect *permissions* in my account, CloudFormation refuses to deploy unless I
explicitly acknowledge it. This is a safety gate, not a bug. Three capability flags:

- **`CAPABILITY_IAM`** — template creates IAM resources (roles, policies, instance profiles)
  but lets CloudFormation **auto-generate their names**.
- **`CAPABILITY_NAMED_IAM`** — required when any IAM resource has an **explicit custom name**
  (e.g. a role named `statuspulse-deploy-role` instead of an auto-generated name). Stricter
  because named roles can collide with existing ones or be referenced by other services.
- **`CAPABILITY_AUTO_EXPAND`** — required when the template uses **macros / Transforms**
  (e.g. SAM, `AWS::Include`) that expand into more resources at deploy time.

Without the right flag I get an **`InsufficientCapabilities`** error. In the CLI:
```bash
aws cloudformation deploy ... --capabilities CAPABILITY_NAMED_IAM
```
> Phase 4 relevance: the GitHub Actions OIDC role is a **named IAM role**, so my CI deploy
> will need `CAPABILITY_NAMED_IAM`. Noting this now so it's not a Sunday surprise.

---

## 7. How a deploy actually runs (dependency ordering)

CloudFormation builds a **dependency graph** and creates resources in the right order,
parallelising what it can. Two ways dependencies form:

1. **Implicit** — if `MyInstance` does `!Ref MySecurityGroup`, CFN knows the SG must exist first.
   This is why my `WebStack` log showed `MySecurityGroup` and `MyEIP` finishing *before*
   `MyInstance`. (My note "SecurityGroup gets updated first" = this graph resolution in action.)
2. **Explicit** — `DependsOn: [ThingA]` forces an order when there's no Ref-based link.

On any failure mid-create, the default behaviour is **automatic rollback** — CFN deletes what it
already made so you don't end up with half a stack. This all-or-nothing behaviour is the whole
point of using CFN over running CLI commands by hand.

---

## 8. The two deploy paths (console did it for me; CLI is Phase 3)

- **Console**: upload template → fill parameters → check capability boxes → create.
- **CLI** (Phase 3 preview):
  - Low level: `create-stack` / `update-stack` / `delete-stack` (you manage change sets yourself).
  - High level: `aws cloudformation deploy` — creates-or-updates in one command, handles the
    change set for you. This is the one I'll lean on.
  - `package` uploads local artifacts (e.g. Lambda zips) to S3 and rewrites the template — only
    needed once I have code artifacts.

---

## My open questions — ANSWERED

**Q: Is `!Ref` on a resource the same as on a parameter?**
No — same syntax, different return. On a parameter it returns the *value*; on a resource it
returns the *physical ID*, and *which* ID depends on the resource type (look it up per type).

**Q: When exactly does an update replace vs modify a resource in place?**
Property-dependent. Each resource property in the AWS docs is tagged with an "Update requires:"
note — `No interruption`, `Some interruption`, or `Replacement`. Always create a change set and
read the **Replacement** column before executing. Never trust an update blind on stateful resources.

**Q: How do separate stacks share data (e.g. a VPC ID between networking and app stacks)?**
Two mechanisms: (a) **Outputs + Export / `!ImportValue`** — simple, but creates a hard
dependency that blocks deletion. (b) **SSM Parameter Store** — looser coupling, one stack writes
a parameter, another reads it; preferred for things that change independently. For the POC,
Export/ImportValue is fine.

**Q: Do I need `CAPABILITY_NAMED_IAM` for the POC?**
Yes — the moment I create a named IAM role (the OIDC deploy role in Phase 4). If I let CFN
auto-name roles, `CAPABILITY_IAM` would suffice, but I want a readable role name, so NAMED it is.

**Q: What's the difference between `Default` in a parameter and a Mapping?**
`Default` is a single fallback value for one input. A `Mapping` is a static lookup table for
*deriving* a value from a key (classic use: pick the right AMI per region). I don't need Mappings
until the template must vary by region.

**Q: YAML or JSON?**
YAML for hand-authoring — comments, multiline strings (UserData scripts), less punctuation.
JSON only if a tool emits it. The repo I'm dissecting is YAML, so I'll stay in YAML.

---

## New open questions (for Phase 2 as I read the repo)
- Which resources in the repo force **Replacement** on update? (audit the stateful ones)
- Are stacks wired via `Export`/`ImportValue` or SSM? (tells me the coupling design)
- Any `Conditions` already used for dev/prod, or is that my Phase 5 improvement?
- Is there a `Transform` (SAM) anywhere → would need `CAPABILITY_AUTO_EXPAND`.

---

## One-line summary to keep in my head
> A **template** declares desired state; a **stack** is that state made real and tracked as one
> unit; **parameters** make it reusable, **functions** wire values together, **outputs/exports**
> expose them, **change sets** show the diff before it bites, and **capabilities** are the safety
> gate for anything that touches permissions.