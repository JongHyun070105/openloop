# AWS deployment

OpenLoop uses an event-driven AWS baseline. There is no always-on EC2 instance,
ECS service, RDS database, or NAT Gateway.

## Resources

- API Gateway HTTP API invokes the FastAPI container on Lambda through AWS Lambda Web Adapter.
- HTTP API throttling defaults to 5 requests/second with a burst of 10. API Lambda reservation is optional and defaults to 0 (the account default), because AWS can reject a small reservation when the account has too little unreserved concurrency. These are abuse/cost guards, not a billing hard cap.
- DynamoDB uses on-demand capacity and a retained table. `GSI1` indexes due checkpoints.
- EventBridge Scheduler wakes one 128 MB Lambda every 15 minutes. The schedule is disabled by default.
- The dispatcher sends due checkpoint work to a FIFO SQS queue.
- When `FcmSecretArn` is supplied, a short-lived queue consumer sends Android and iOS notifications through FCM HTTP v1. The API reports server push as enabled only in that configuration, so the client cannot mistake device-token storage for deliverable push. iOS delivery uses Firebase's APNs bridge and still requires APNs credentials in the Firebase project.
- CloudWatch application and access logs expire after 7 days.
- An optional AWS Budget sends alerts at 50% actual, 80% forecast, and 100% actual monthly spend.

This baseline deliberately avoids a VPC. Adding a Lambda to private subnets usually introduces NAT Gateway or VPC endpoint costs and is not required for the public APIs used by the MVP.

## Before deployment: stop unexplained charges

The default AWS profile currently fails `sts:GetCallerIdentity`. The separately configured `hermes-aws` profile was refreshed and used for inventory and the explicitly requested dev deployment. It is configured with root credentials, so it should be replaced with a least-privilege IAM role or IAM Identity Center session before routine deployment work.

The 2026-08-16 inventory found the recurring `EC2 - Other` source in `ap-northeast-2`:

- stopped EC2 instance `i-0b6be8996efcc29c7` (`hermes-cloud-worker`, `t4g.micro`);
- attached 20 GiB gp3 root volume `vol-06a1dd41bcd95c852`;
- the root volume has `DeleteOnTermination=true`;
- no account-owned snapshot, Elastic IP address, or active NAT Gateway was found in that region.

A stopped instance does not incur instance compute charges, but its attached EBS volume continues to incur storage charges. On 2026-08-16, the unused instance was terminated and its attached root volume was deleted at the user's request. A subsequent inventory confirmed that `vol-06a1dd41bcd95c852` no longer exists.

After replacing the local AWS profile with a valid, least-privilege profile, inspect every active region before deleting anything:

```bash
aws sts get-caller-identity
aws configure list
aws ec2 describe-regions --query 'Regions[].RegionName' --output text
aws ce get-cost-and-usage \
  --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

The screenshot points mostly to `EC2 - Other`; the inventory confirms EBS volume usage in this account. Use Cost Explorer's usage-type grouping to re-check the cost immediately before cleanup:

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=USAGE_TYPE

aws ec2 describe-volumes --region ap-northeast-2
aws ec2 describe-snapshots --owner-ids self --region ap-northeast-2
aws ec2 describe-addresses --region ap-northeast-2
aws ec2 describe-nat-gateways --region ap-northeast-2
aws kms list-keys --region ap-northeast-2
aws glue get-databases --region ap-northeast-2
```

Deletion is intentionally not scripted: snapshots, KMS keys, and buckets can contain unrecoverable data, and KMS deletion has a waiting period. Identify the exact resource ARN, confirm it is unused, and take a backup before removal. Creating a Budget alerts on future cost but does not cap or automatically stop AWS usage.

## Secret boundary

For local development, provider API keys may be placed in the ignored `services/api/.env` file and must never be committed, printed in logs, or sent through chat. Start the API with `.venv/bin/uvicorn --env-file .env app.main:app --reload`; keep `services/api/.env.example` empty as the versioned template. For AWS, do not put them in SAM parameters, build arguments, or GitHub Actions variables. Use at most two Secrets Manager secrets: one consolidated API-integration JSON object and one Firebase service-account object. Each Lambda can read only the ARN it needs.

| Parameter | Lambda environment hook | Expected secret fields |
| --- | --- | --- |
| `IntegrationSecretArn` | `INTEGRATION_SECRET_ARN` | JSON shown below |
| `FcmSecretArn` | `FCM_SECRET_ARN` | complete Firebase service-account JSON object |

```json
{
  "GEMINI_API_KEY": "...",
  "KAKAO_REST_API_KEY": "...",
  "KMA_AUTH_KEY": "...",
  "POSTHOG_PROJECT_API_KEY": "...",
  "SENTRY_DSN": "..."
}
```

Only include issued credentials. `GEMINI_MODEL` and `POSTHOG_HOST` may also live in this JSON, but explicit non-empty Lambda environment values take precedence. `IntegrationSecretArn` is optional, so the deterministic adapters continue to work before any provider key is issued. Without a model key, analysis is deliberately conservative: it extracts only explicit values and asks for missing fields instead of returning demo data.

After adding a provider value to `services/api/.env`, synchronize the server-side secret without exposing the value in a command or log:

```bash
cd services/api
.venv/bin/python scripts/sync_integration_secret.py --dry-run
.venv/bin/python scripts/sync_integration_secret.py
```

The command preserves existing remote values when the corresponding local `.env` value is blank. Run a normal SAM deploy afterwards when an immediate Lambda refresh is required.

Non-secret configuration is passed separately through `GEMINI_MODEL`, `FCM_PROJECT_ID`, `POSTHOG_HOST`, and `OPENLOOP_DEFAULT_USER_ID`. The default Gemini model is the stable, cost-oriented `gemini-3.5-flash-lite`; pin a different stable model through the deployment parameter when evaluation supports it.

AWS promotional credits generally exclude AWS Marketplace purchases. Bedrock third-party model spend is covered only by eligible AWS Activate credits, so confirm the credit type and Billing console treatment before choosing Bedrock or a Marketplace-delivered model.

Secrets Manager has a recurring per-secret charge. Consolidating the five API integrations avoids five separate fixed charges; FCM remains separate because only the notification worker should read its service account. Create either secret only when its integration is selected, and delete unused versions or the entire unused secret according to the provider migration plan.

## Local validation

Prerequisites: Docker and AWS SAM CLI.

```bash
python3 -m unittest discover -s infra/checkpoint -p 'test_*.py' -v
python3 -m unittest discover -s infra/checkpoint_worker -p 'test_*.py' -v
sam validate --lint --template-file infra/template.yaml
sam build --template-file infra/template.yaml --use-buildkit
docker build --tag openloop-api:local .
docker run --rm -p 8080:8080 openloop-api:local
curl --fail http://127.0.0.1:8080/health
```

`sam validate` is credential-free. Deployment is not.

## Deploy when credentials are ready

Deploy first with the scheduler disabled and without an AI secret:

```bash
sam build --template-file infra/template.yaml --use-buildkit
sam deploy \
  --profile <aws-profile> \
  --stack-name openloop-dev \
  --region ap-northeast-2 \
  --resolve-image-repos \
  --resolve-s3 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Environment=dev \
    CheckpointScheduleState=DISABLED \
    MonthlyBudgetUsd=10 \
    BudgetAlertEmail=you@example.com
```

Add `IntegrationSecretArn` only after the consolidated secret exists. Add `FcmSecretArn` separately; the FCM worker is not created without it. Enable `CheckpointScheduleState=ENABLED` only after that worker and its Firebase/APNs credentials are tested. Restrict CORS to the production web origin before a browser client is exposed publicly.

## Current dev deployment

Deployed on 2026-08-16 in `ap-northeast-2`:

- stack: `openloop-dev`;
- API: `https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev`;
- DynamoDB table: `openloop-dev-OpenLoopTable-14SVG6YM5PUV8`;
- checkpoint schedule: `DISABLED`;
- AI provider: `gemini-3.5-flash-lite`, loaded only from the server-side integration secret;
- Kakao Local place search: configured and live-verified;
- KMA weather: 4.3 단기예보 API utilization approval applied; the live endpoint was verified with a successful forecast response on 2026-08-16.

The dev API is intentionally unauthenticated for integration testing. Add authentication, restrict CORS, and enable request-abuse controls before treating it as a production endpoint.

## Checkpoint item contract

The dispatcher queries records shaped like this:

```json
{
  "PK": "LOOP#<loop-id>",
  "SK": "CHECKPOINT#<checkpoint-id>",
  "GSI1PK": "CHECKPOINT#OPEN",
  "GSI1SK": "2026-08-16T03:00:00Z",
  "userId": "user-uuid",
  "notificationTitle": "출발할 시간이에요",
  "notificationBody": "지금 출발하면 늦지 않아요.",
  "checkpointStatus": "open",
  "expiresAt": 1786852800
}
```

On dispatch, it writes an idempotent FIFO message and removes the GSI keys so the checkpoint is not selected again. Consumers must still be idempotent because distributed delivery is at least once.

## Device-token storage contract

The API owns registration, refresh, and user-scoped deletion of device tokens. The notification worker has only `GetItem`, `Query`, and `UpdateItem`; it cannot create tokens or read other tables.

```json
{
  "PK": "USER#<user-id>",
  "SK": "DEVICE#<stable-device-id-or-token-hash>",
  "fcmToken": "<FCM registration token>",
  "platform": "ios",
  "active": true,
  "updatedAt": "2026-08-16T03:00:00Z",
  "expiresAt": 1786852800
}
```

- `platform` is `ios` or `android`. Both use an FCM registration token; never send the raw APNs token to this worker.
- On FCM `UNREGISTERED`, or a token-specific `INVALID_ARGUMENT`, the worker marks the token inactive instead of retrying it forever.
- Mobile clients must upsert after installation and token refresh, and deactivate the record on logout before switching accounts.
- Until authentication is implemented, the client sends a stable random UUID through `X-OpenLoop-Install-Id`. The API validates the UUID and uses it as `owner_id`; checkpoints copy that value to `userId`, and device records use `PK=USER#<installation-id>`.
- `OPENLOOP_DEFAULT_USER_ID=dev-local` is only a local/dev fallback when the header is absent. The SAM template sets `OPENLOOP_REQUIRE_INSTALL_ID=true` for `Environment=prod`, so production requests must never share the fallback partition.
- Token values are sensitive operational identifiers. Do not log them or include them in analytics or error payloads.
- DynamoDB encryption at rest is enabled, but API authorization must still ensure a user can mutate only their own `USER#<user-id>` partition.

## Teardown

```bash
sam delete --stack-name openloop-dev --region ap-northeast-2
```

The DynamoDB table is retained by design. After stack deletion, inspect the retained table and delete it separately only if its data is no longer needed. Budget resources and container image repositories should also be checked in the Billing and ECR consoles.
