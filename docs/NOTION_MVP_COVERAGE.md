# Notion MVP coverage

This is the implementation audit for the `Capture → Create → Close` portion of
the OpenLoop product brief. It distinguishes shipped MVP/v1 behavior from the
brief's later roadmap so a planned skill is not mistaken for a missing button.

| Brief capability | Shipped behavior | Evidence surface |
| --- | --- | --- |
| Text, screenshot, image capture | Flutter capture, Android share intent, iOS Share Extension, and a pure native-share payload test | `apps/mobile/lib/services/shared_capture.dart` |
| Multiple related screenshots | Up to five temporary image files are sent in one multipart request and one Gemini multimodal context; neither file path nor bytes are persisted | `services/api/app/main.py`, `services/api/app/analyzer.py` |
| Appointment / deadline classification | Strict two-intent schema with deterministic safe fallback | `services/api/app/models.py`, `services/api/app/demo_analyzer.py` |
| Final-agreement extraction | Gemini instruction resolves the latest agreement; fallback takes only explicit facts | `services/api/app/analyzer.py` |
| AI summary + confidence review | A factual Korean `summary` and field-level confidence chips are displayed in review and detail | `apps/mobile/lib/app.dart` |
| Missing fields / one-question verification | `needs_input` loops request one field at a time and refresh local actions/summary after each answer | `apps/mobile/lib/app.dart`, `apps/mobile/lib/app_controller.dart` |
| Action graph | Calendar, reminder, place, checklist, and checkpoints are persisted and independently completable | `services/api/app/service.py` |
| Deadline closeout | Explicit checklist plus D-7 / D-3 / D-1 checkpoints | `services/api/app/service.py` |
| Appointment follow-up | T-24h / T-2h / T+1d checkpoints | `services/api/app/service.py` |
| Privacy and Close & Forget | PII redaction before text inference, no raw image persistence, and completion-time retention deadlines | `services/api/app/privacy.py`, `apps/mobile/lib/app_controller.dart` |

## Deliberately later roadmap

The source brief places login/billing, collaborative loops, arbitrary URL-page
fetching, PDFs/email/audio/messenger ingestion, reservations/purchases, travel,
and other skills after the personal-loop MVP. They are not represented as
partially working features in this app. Server push is implemented behind its
Firebase/APNs credential boundary and remains disabled until those secrets are
configured and device permission testing is complete.
