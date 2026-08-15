# Architecture

```text
Screenshot / Image / Text
            |
      Flutter / Web
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
- `apps/mobile` owns capture, review, Loop presentation, calendar permission, and notifications.
- `services/api` owns orchestration, normalized contracts, context resolution, confidence, action graphs, and scheduling.
- External providers live behind adapters. Domain models must not depend on a specific LLM, calendar, map, or push provider.

## Core entities

- `StructuredEvent`: normalized appointment or deadline with field confidence.
- `OpenLoop`: event plus lifecycle (`open`, `needs_input`, `closed`).
- `LoopAction`: calendar, reminder, place, or checklist action.
- `Checkpoint`: scheduled context reevaluation, not a continuously running agent.

## Next implementation slices

1. Shared JSON Schema and generated Dart/TypeScript clients.
2. Multimodal model adapter with redaction and structured-output validation.
3. SQLite development repository, then PostgreSQL production repository.
4. Native share extension and calendar integration.
5. Golden dataset focused on Final Agreement Accuracy.
