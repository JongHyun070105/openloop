# Architecture

```text
One screenshot / image or text
            |
      Flutter mobile
            |
         FastAPI
            |
  multimodal AI adapter
            |
 Analysis Draft + confidence
            |
      user verification
            |
         approval
            |
       OpenLoop store
        /    |     \
 Calendar  Action  Checkpoint
                         |
                   event-driven agent
```

## Boundaries

- `apps/demo` is a deterministic judging prototype. It demonstrates product behavior without credentials.
- `apps/mobile` owns capture, review, Loop presentation, Android/iOS sharing,
  calendar handoff, local reminders, and device-side permissions.
- `services/api` owns orchestration, normalized contracts, context resolution, confidence, action graphs, and scheduling.
- External providers live behind adapters. Domain models must not depend on a specific LLM, calendar, map, or push provider.

## Core entities

- `AnalyzeResponse`: nonpersisted `Analysis Draft` containing a normalized appointment, deadline, place, or coupon, a factual Korean summary, confidence, missing fields, and at most one focused question.
- `OpenLoop`: event plus lifecycle (`open`, `needs_input`, `closed`) and conservative same-place relation IDs.
- `LoopAction`: calendar, reminder, place, coupon, or checklist action.
- `Checkpoint`: scheduled context reevaluation, not a continuously running agent.

## Current delivery topology

- The API persists local development data in SQLite and deployed data in
  DynamoDB. Its Lambda/Web Adapter deployment is defined in `infra/`.
- `POST /v1/analyze` and `POST /v1/analyze/image` do not persist. The Flutter Review screen edits the draft locally; approval calls `POST /v1/loops` exactly once.
- The image API accepts exactly one JPEG, PNG, WebP, HEIC, or HEIF file up to 10 MB. Raw uploads remain request-scoped and are not part of Loop data.
- Flutter sends its capture-time `reference_at`; the Gemini adapter uses that authoritative `Asia/Seoul` instant in every prompt, uses `MINIMAL` thinking for text and `LOW` for image, validates structured output, and gates required fields below `0.65` confidence. The server uses its KST clock only for legacy callers that omit it.
- Image analysis never falls back to a text-only parser. Text analysis may use the deterministic, explicit-facts-only adapter when Gemini is unavailable.
- Kakao and KMA provide normalized place and weather data. The Flutter client
  opens the native Kakao map when possible and otherwise uses the web URL.
- Action, checklist, and checkpoint mutations are installation-scoped and
  local-first: a failed remote request preserves the user’s local progress.
- Default checkpoint policy creates at most one useful alert: Appointment `T-1h` or the nearest remaining `T-15m` / `T-5m`; Deadline/Coupon `D-1` or `D-day`. A saved place creates none. API and mobile apply the same policy.
- v2.5 context starts with deterministic same-owner, normalized same-place links. Fuzzy semantic linking remains deferred so the UI can always explain why two Loops are related.

## Delivery status

| Boundary | Status |
| --- | --- |
| Single-image capture, nonpersisted draft, KST Gemini contract, confidence gate, lifecycle API | Implemented with automated contract tests |
| 100-case synthetic evaluation harness | Implemented and dataset-validated; live provider runs remain opt-in and billable |
| System calendar, local reminders, adaptive delete confirmation | Implemented; release evidence still requires Android/iOS runtime checks |
| FCM checkpoint push | Credential-gated; do not claim live delivery until Firebase/APNs setup and device acceptance tests pass |
| PostHog and Sentry | Credential-gated; disabled-safe without keys |
| Production authorization | Not implemented; installation UUID ownership is not authentication |

## Remaining production slices

1. User authentication and durable authorization beyond installation IDs.
2. Checkpoint-time weather/place context reevaluation instead of a static stored payload.
3. Provider credential activation and real-device permission/push acceptance testing.
4. Billing and multi-user sharing only after the personal-loop flow is validated.
5. Purchase/reservation/travel skill modules and model-inferred cross-Loop context.
