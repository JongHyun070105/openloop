# Notion MVP coverage

This is the implementation audit for the `Capture → Create → Close` portion of
the OpenLoop product brief. It distinguishes shipped MVP/v1 behavior from the
brief's later roadmap so a planned skill is not mistaken for a missing button.

| Brief capability | Shipped behavior | Evidence surface |
| --- | --- | --- |
| Text, screenshot, image capture | Flutter capture, Android `SEND`, and iOS Share Extension accept text or exactly one image; a replacement image replaces the prior selection | `apps/mobile/lib/services/shared_capture.dart`, platform manifests |
| Analysis before creation | `/v1/analyze*` returns a nonpersisted draft; approval calls `/v1/loops`, preventing abandoned-review ghost Loops | `services/api/app/main.py`, `apps/mobile/lib/app_controller.dart` |
| Appointment / deadline / place / coupon classification | Strict four-intent schema; places and coupons never inherit appointment-only time requirements | `services/api/app/models.py`, `services/api/app/analyzer.py`, `services/api/app/demo_analyzer.py` |
| Temporal/final-agreement extraction | Capture sends an explicit KST `reference_at`; Gemini uses `LOW` image thinking and applies relative-date, omitted-year, and latest-agreement rules | `services/api/app/analyzer.py`, `apps/mobile/lib/services/analyze_service.dart` |
| AI summary + confidence review | Factual Korean summary; raw percentages are debug-only unless a field needs confirmation | `apps/mobile/lib/app.dart` |
| Missing/low-confidence verification | Required values below `0.65` or absent enter `needs_input`; the provider's focused question is preserved | `services/api/app/analyzer.py`, `apps/mobile/lib/models/open_loop.dart` |
| Native review completion | Review facts are editable, Appointment approval opens the system calendar composer, and delete confirmation is Cupertino/Material adaptive | `apps/mobile/lib/app.dart` |
| Action graph | Calendar, reminder, place, coupon, checklist, and at-most-one contextual alert are persisted | `services/api/app/service.py` |
| Deadline/coupon closeout | Date-only captures never ask for time; one future D-1 or D-day alert | `services/api/app/service.py`, `apps/mobile/lib/services/checkpoint_planner.dart` |
| Appointment follow-up | One future T-1h alert or nearest useful T-15m/T-5m fallback | `services/api/app/service.py`, `apps/mobile/lib/services/checkpoint_planner.dart` |
| v2.5 context foundation | Same installation and normalized same-place Loops are linked symmetrically and shown in Detail | `services/api/app/service.py`, `apps/mobile/lib/app_controller.dart`, `apps/mobile/lib/app.dart` |
| Privacy and Close & Forget | PII redaction before text inference, no raw image persistence, and completion-time retention deadlines | `services/api/app/privacy.py`, `apps/mobile/lib/app_controller.dart` |
| AI quality gate | Versioned 100-case synthetic set and opt-in adapter/API runner with five 95% accuracy gates | `services/api/evals/`, `docs/AI_EVALUATION.md` |

## Deliberately later roadmap

The source brief places login/billing, collaborative loops, arbitrary URL-page
fetching, PDFs/email/audio/messenger ingestion, purchase/reservation/travel
skills, and fuzzy semantic Loop relationships after this release. They are not
represented as partially working features in this app.

## Activation boundary

- FCM remote push, PostHog, and Sentry are implemented but credential-gated and disabled-safe. They are not live-delivery evidence.
- Gemini, Kakao, and KMA adapters are implemented; each still depends on valid server credentials and provider-side availability.
- Installation UUID ownership is not authentication. Public multi-user authorization remains future production work.
- Checkpoint-time weather/place reevaluation remains a v1.3 completion slice; current checkpoint persistence does not prove dynamic agent output.
