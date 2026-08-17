# OpenLoop product completion plan

Status: v2 capture expansion implemented; release evidence in progress
Source: Notion `OpenLoop 구체화`, refreshed 2026-08-16
Scope: personal Appointment + Deadline + Place + Coupon product and deterministic v2.5 context foundation

## Defects resolved in this implementation

1. Flutter used to send selected images as `application/octet-stream`, which the image endpoint correctly rejected with 415; it now supplies the actual supported MIME type.
2. The mobile controller used to hide image errors behind a text-only local parser; image failures now stay visible and retryable.
3. Gemini lacked an explicit Korean reference date/time; Capture now supplies a timezone-aware `reference_at` through the adapter.
4. Provider output is normalized into a safe, focused draft or an explicit retryable error.
5. The former five-image contract has been reduced across capture, share targets, API, and tests to one screenshot.
6. Delete confirmation is now Cupertino-destructive on iOS and Material-destructive on Android.
7. Provider questions and draft state are preserved through the ambiguity/review flow.
8. Analysis returns an unpersisted draft; the server Loop is created only after approval.
9. Low-confidence or absent required fields enter one focused verification gate instead of appearing final.
10. Overbuilt reminder cadences were replaced by one useful alert, with no checkpoint at all for saved places.
11. Place and coupon captures no longer ask appointment-only date/time questions.
12. Explicit same-place Loops link symmetrically without opaque fuzzy inference.

## Reference acceptance case

Given the attached messenger screenshot and a reference instant of
`2026-08-16T11:01:00+09:00`, the product must produce:

- intent: Appointment
- title/purpose: perfume transaction
- date: `2026-08-16`
- start time: `16:00:00`
- place: `종로5가역 12번 출구`
- missing fields: none
- next screen: Review, not Ambiguity

## Execution order

### Phase 0 - Lock failing contracts

- Add backend tests for KST temporal grounding, single-image rejection, final agreement, and safe provider normalization.
- Add Flutter tests for explicit image MIME, one multipart file, no image-to-text fallback, first shared image only, and adaptive delete confirmation.
- Replace tests that currently require multiple images.

Gate: the new tests fail for the current behavior for the expected reason.

### Phase 1 - Repair Capture and AI correctness

- Send the actual image MIME type from Flutter.
- Reduce mobile capture, Android share, iOS Share Extension, API schema, and Gemini adapter to one image.
- Add a server-generated `Asia/Seoul` reference instant to every text and image prompt.
- Define relative-date and omitted-year rules explicitly.
- Normalize recoverable provider state inconsistencies before strict domain validation; log only safe field/type diagnostics.
- Align mobile timeouts with the server and expose retryable image failures instead of a fake parsed loop.
- Use low thinking for image context resolution and keep cheaper minimal thinking for clear text, following the selected model's documented quality/latency controls.

Gate: the reference case succeeds repeatedly against real Gemini and no raw input is logged or persisted.

### Phase 2 - Native, confidence-aware review

- Return an unpersisted Analysis Draft first; create the server Loop only after user approval.
- Add a deterministic confidence validator so a low-confidence value is verified even when the model populated it.
- Replace the delete alert with adaptive platform confirmation.
- Preserve and render the server's focused question.
- Hide raw confidence percentages in normal builds; show only field-level confirmation when needed.
- Make review facts individually editable through native date/time and focused text/place controls.
- For a complete appointment, make the primary review action save the loop and open the system calendar composer.
- Move provider URL/status configuration behind debug mode; keep only user settings in production.

Gate: a clear capture completes in share -> review -> system calendar, and an ambiguous capture asks only one real question.

### Phase 3 - Closure and context

- Verify Appointment T-1h/near-term fallback, Deadline/Coupon D-1/day-of fallback, and zero Place checkpoints.
- Re-evaluate KMA/weather and available place context when a checkpoint fires instead of sending only a static stored sentence.
- Verify Kakao place, KMA forecast, calendar, local reminder, completion, retention, and deletion flows.
- Keep remote push credential-gated and clearly report activation state.

Gate: the loop can be created, acted on, completed, and removed under every retention policy.

### Phase 3.5 - v2/v2.5 expansion

- Classify and review saved places and coupons with type-specific required fields.
- Keep coupon expiry date separate from appointment date/time.
- Link same-owner Loops only when their explicit normalized place matches.
- Defer fuzzy semantic relations and purchase/reservation/travel skills until their explanations, data contracts, and acceptance tests are designed.

Gate: place/coupon captures never enter a fake time question, and every displayed relation has a deterministic same-place explanation.

### Phase 4 - Evaluation and release evidence

- Build a versioned 100-case evaluation set: 20 clear appointments, 20 time changes, 15 place changes, 15 relative dates, 15 missing fields, and 15 poster/deadline cases.
- Measure Date, Time, Location, Field, and Final Agreement accuracy.
- Require at least 95% final structured-field accuracy for the curated MVP set and 100% on critical reference regressions.
- Run Flutter analyzer/tests, backend tests, SAM checks, Android APK and iOS simulator builds.
- Capture actual Android external share, iOS Share Extension, native confirmation, reference AI result, and Loop Closed evidence.

Gate: every Notion MVP/v1.3 requirement has direct code, test, and runtime evidence; no result is inferred from a narrow test.

## Safety and privacy invariants

- The image exists only in the capture/request lifecycle and is never stored in Loop data.
- Logs, telemetry, and errors never contain image bytes, raw conversation text, credentials, or installation identifiers.
- Text PII is redacted before remote inference where possible.
- Image analysis failure never becomes an apparently successful local AI result.
- Credentials remain in ignored `.env` files or AWS Secrets Manager only.
