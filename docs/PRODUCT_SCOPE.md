# MVP Product Scope

## Promise

OpenLoop converts information users already understood into a structured, actionable schedule. The first five-second message is “capture to calendar”; deeper value comes from context resolution, confidence-aware verification, and closure.

## In scope

### Inputs

- Screenshot
- Image
- Text

Android `SEND`/`SEND_MULTIPLE`과 iOS Share Extension은 한 번에 최대 5장의
이미지를 하나의 캡처 맥락으로 전달한다. 텍스트와 URL 공유 문자열은 같은
보조 문맥으로 보존한다. URL 원문을 서버가 임의로 가져오는 기능은 SSRF와
개인정보 경계 때문에 MVP에 포함하지 않는다.

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
8. A concise, factual Korean summary for the review screen

### Actions

- Calendar event
- Reminder
- Open Loop
- Deadline checklist
- Deadline checkpoints (`D-7`, `D-3`, `D-1`)
- Appointment checkpoints (`T-24h`, `T-2h`, `T+1d`)

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

- Text, image, and native Android/iOS share capture (up to five images) feed the same review flow.
- The FastAPI service uses a structured Gemini adapter when configured and
  degrades to a deterministic local-safe analysis path when it is unavailable.
- Both remote and local analysis return an explicit Korean review summary;
  selecting a missing field refreshes the summary and action graph.
- Calendar handoff, local reminders, Kakao place lookup/map handoff, and KMA
  weather lookup are wired behind permission and provider-availability checks.
- Appointment and deadline loops persist actions, checklist items, and their
  distinct checkpoint cadence; each can be completed locally and synced to the
  server when reachable.
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
