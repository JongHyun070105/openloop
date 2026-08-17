# MVP Product Scope

## Promise

OpenLoop converts information users already understood into a structured, actionable schedule. The first five-second message is “capture to calendar”; deeper value comes from context resolution, confidence-aware verification, and closure.

## In scope

### Inputs

- Screenshot
- Image
- Text

Android `SEND`와 iOS Share Extension은 이미지 한 장만 전달한다. 새 이미지
선택은 기존 이미지를 교체한다. 텍스트와 URL 공유 문자열은 같은 보조 문맥으로
보존하지만, URL 원문을 서버가 임의로 가져오지는 않는다.

### Intents

- `appointment`: appointment, event, reservation
- `deadline`: notice, submission, application
- `place`: restaurant, cafe, shop, venue, or destination saved for later
- `coupon`: coupon, voucher, discount, or benefit with an optional expiry date

### AI pipeline

1. Input classification
2. Entity extraction
3. Context resolution (correction, rejection, final agreement)
4. Field-level confidence
5. Missing-field detection
6. Nonpersisted `Analysis Draft`
7. Focused user verification
8. Approval-only Open Loop and action-graph creation
9. A concise, factual Korean summary for the review screen

The capture client sends an explicit `reference_at`, which Gemini receives as an
`Asia/Seoul` reference instant. Text uses `MINIMAL` thinking and image uses `LOW`.
Required fields below `0.65`
confidence join `missing_fields` and require focused verification.

### Actions

- Calendar event
- Reminder
- Open Loop
- Deadline checklist
- Place/map handoff and coupon-use action
- One contextual alert: Appointment `T-1h` (or the nearest remaining `T-15m` / `T-5m`), Deadline/Coupon `D-1` (or `D-day`)
- No checkpoint for a saved place
- Conservative same-place links between Loops owned by the same installation

## UX rules

- Actions are direct user work such as calendar, place, and checklist; checkpoints are timed prompts that support those actions.
- On first app launch, request the system notification permission and automatically schedule future local checkpoint alerts after approval.

- Form entry becomes AI review.
- One screen asks for one decision.
- Analysis does not create a server Loop. Approval does.
- High confidence enables one primary creation action.
- Low confidence asks only about the uncertain field.
- Incomplete events remain Open Loops instead of being guessed.
- Appointment approval saves the Loop and opens the system calendar composer.
- Destructive confirmation and date/time selection use platform-adaptive UI.

## Privacy rules

- No surveillance: process only explicitly shared content.
- Local-first preprocessing and OCR where possible.
- Redact unnecessary PII before external inference.
- Keep structured data; minimize raw capture retention.
- Close & Forget retention options: immediately, 7 days, 30 days, or keep.

## Deliberately deferred

- Production authentication and billing
- Account-to-account sharing and collaborative editing
- Purchase, reservation, travel, school, and work skills beyond the four current capture types
- Fuzzy or model-inferred cross-Loop relationships beyond explicit same-place context
- Production authentication and authorization beyond installation ownership

## Implemented product paths

- Text, one image, and native Android/iOS share capture feed the same review flow.
- The FastAPI service uses a structured Gemini adapter when configured. A
  deterministic fallback is limited to text in an intentionally offline/local
  setup; configured remote failures and all image failures remain explicit,
  retryable errors.
- Analysis endpoints return a nonpersisted draft; user approval creates the Loop.
- Both remote and local analysis return an explicit Korean review summary;
  selecting a missing field refreshes the summary and action graph.
- Calendar handoff, local reminders, Kakao place lookup/map handoff, and KMA
  weather lookup are wired behind permission and provider-availability checks.
- Appointment, deadline, place, and coupon loops persist only the actions and
  contextual alert defined above; same-place Loops are linked without fuzzy inference.
- The checked-in 100-case synthetic evaluation covers clear appointments, time
  changes, place changes, relative dates, missing fields, and poster/deadline input.

## Activation status

| Capability | Status |
| --- | --- |
| Core Capture → Draft → Approval → Close path | Implemented with automated tests; Android/iOS release QA is tracked separately |
| Gemini/Kakao/KMA adapters | Implemented; actual availability depends on server credentials and provider approval |
| FCM remote checkpoint push | Implemented behind Firebase/APNs credentials; no live-delivery claim without device verification |
| PostHog and Sentry | Implemented behind keys with privacy-safe disabled defaults |
| Public multi-user security | Future work; installation UUID is not production authentication |

## External activation prerequisites

- Gemini, Kakao, and KMA credentials belong only on the server.
- Firebase configuration plus the FCM service-account secret are required to
  activate remote checkpoint push.
- PostHog and Sentry keys are required to activate analytics and error capture.
- Platform permissions and provider-side KMA authorization still determine
  whether those integrations can complete on a particular device/account.
