# MVP Product Scope

## Promise

OpenLoop converts information users already understood into a structured, actionable schedule. The first five-second message is “capture to calendar”; deeper value comes from context resolution, confidence-aware verification, and closure.

## In scope

### Inputs

- Screenshot
- Image
- Text

### Intents

- `appointment`: appointment, event, reservation
- `deadline`: notice, submission, application

### AI pipeline

1. Input classification
2. Entity extraction
3. Context resolution (correction, rejection, final agreement)
4. Field-level confidence
5. Missing-field detection
6. Focused user verification
7. Action graph generation

### Actions

- Calendar event
- Reminder
- Open Loop
- Deadline checklist
- Event-driven checkpoints (`T-24h`, `T-2h`, `T+N`)

## UX rules

- Form entry becomes AI review.
- One screen asks for one decision.
- High confidence enables one-tap creation.
- Low confidence asks only about the uncertain field.
- Incomplete events remain Open Loops instead of being guessed.

## Privacy rules

- No surveillance: process only explicitly shared content.
- Local-first preprocessing and OCR where possible.
- Redact unnecessary PII before external inference.
- Keep structured data; minimize raw capture retention.
- Close & Forget retention options: immediately, 7 days, 30 days, or keep.

## Deliberately deferred

- Production authentication and billing
- A golden prompt-evaluation dataset and automated quality gate
- Account-to-account sharing and collaborative editing
- Purchase, coupon, travel, school, and work skills

## Implemented product paths

- Text, image, and native Android/iOS share capture feed the same review flow.
- The FastAPI service uses a structured Gemini adapter when configured and
  degrades to a deterministic local-safe analysis path when it is unavailable.
- Calendar handoff, local reminders, Kakao place lookup/map handoff, and KMA
  weather lookup are wired behind permission and provider-availability checks.
- Appointment and deadline loops persist actions, checklist items, and
  `T-24h`/`T-2h`/`T+N` checkpoints; each can be completed locally and synced
  to the server when reachable.
- DynamoDB-backed serverless persistence, scheduled checkpoint dispatch, FCM,
  PostHog, and Sentry are all optional integrations. They remain explicitly
  disabled until their corresponding credentials are configured, rather than
  pretending to be active.

## External activation prerequisites

- Gemini, Kakao, and KMA credentials belong only on the server.
- Firebase configuration plus the FCM service-account secret are required to
  activate remote checkpoint push.
- PostHog and Sentry keys are required to activate analytics and error capture.
- Platform permissions and provider-side KMA authorization still determine
  whether those integrations can complete on a particular device/account.
