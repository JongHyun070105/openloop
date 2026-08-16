# OpenLoop Mobile

Flutter client for the OpenLoop AI Action Calendar.

The client supports text/image capture, Android share intents, an iOS Share Extension, confidence-aware review, local persistence and retention, calendar handoff, local notifications, and API-to-local fallback. The Firebase SDK requires an iOS 15.0 deployment target.

```bash
flutter pub get
flutter run
```

Connect an API without committing a secret:

```bash
flutter run --dart-define=OPENLOOP_API_BASE_URL=https://your-api.example
```

Without an override, development builds use the deployed OpenLoop AWS dev API.

Text uses `POST /v1/loops/analyze`. Images use multipart `POST /v1/loops/analyze/image` with `file` and optional `companion_text`; both return a server-persisted Loop with its action graph. Ambiguity, checklist, and completion updates are synchronized to `/v1/loops/{id}` endpoints. When the URL is empty or unreachable, the app clearly labels and uses its deterministic local analyzer, which extracts only explicit values and never invents a demo appointment.

Optional integrations are disabled unless every required dart-define is present. Put the public mobile configuration in an uncommitted `.env` file and run it in one command:

```bash
flutter run --dart-define-from-file=.env
```

Supported `.env` names are `OPENLOOP_API_BASE_URL`, `SENTRY_DSN`, `POSTHOG_PROJECT_API_KEY`, `POSTHOG_HOST`, `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, and `FIREBASE_PROJECT_ID`. Firebase must include all four values; otherwise push safely remains disabled.

Kakao and KMA credentials remain server-side. The client only calls the FastAPI place/weather boundaries. PostHog sends allow-listed event names without captured text, titles, places, images, tokens, person profiles, or session replay. Sentry disables PII and screenshots. FCM tokens are sent only to the dedicated backend registration endpoint.

Validation:

```bash
flutter analyze
flutter test
flutter build apk --debug --dart-define-from-file=.env
flutter build ios --simulator --dart-define-from-file=.env
```
