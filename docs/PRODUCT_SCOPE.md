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
- Live LLM calls and prompt evaluation dataset
- Native share extensions
- Real calendar, maps, weather, FCM, and APNs integrations
- PostgreSQL persistence and production scheduler
- Purchase, coupon, travel, school, and work skills
