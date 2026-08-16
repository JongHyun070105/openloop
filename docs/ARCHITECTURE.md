# Architecture

```text
Screenshot / Image / Text
            |
      Flutter mobile
            |
   local preprocessing
            |
         FastAPI
            |
  multimodal AI adapter
            |
 StructuredEvent + confidence
            |
      user verification
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

- `StructuredEvent`: normalized appointment or deadline with field confidence.
- `OpenLoop`: event plus lifecycle (`open`, `needs_input`, `closed`).
- `LoopAction`: calendar, reminder, place, or checklist action.
- `Checkpoint`: scheduled context reevaluation, not a continuously running agent.

## Current delivery topology

- The API persists local development data in SQLite and deployed data in
  DynamoDB. Its Lambda/Web Adapter deployment is defined in `infra/`.
- Gemini accepts text and image analysis through a server-only adapter; raw
  uploads are size/type constrained and not persisted.
- Kakao and KMA provide normalized place and weather data. The Flutter client
  opens the native Kakao map when possible and otherwise uses the web URL.
- Action, checklist, and checkpoint mutations are installation-scoped and
  local-first: a failed remote request preserves the user’s local progress.
- Checkpoint scheduling, FCM delivery, PostHog, and Sentry are credential-gated
  optional integrations with disabled-safe defaults.

## Remaining production slices

1. User authentication and a durable authorization model beyond anonymous installation IDs.
2. A golden evaluation dataset focused on Final Agreement Accuracy.
3. Provider credential activation and real-device permission/push acceptance testing.
4. Billing and multi-user sharing only after the personal-loop flow is validated.
