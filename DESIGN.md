# Design

## Source of truth

- Status: Active
- Last refreshed: 2026-08-20
- Primary product surfaces: Flutter iOS/Android app, Android share intent, iOS Share Extension, contest web prototype
- Evidence reviewed: Notion `OpenLoop 구체화` sections 1-33; prior product screenshots; user-reported iOS simulator behavior on 2026-08-17; `docs/PRODUCT_SCOPE.md`; `docs/ARCHITECTURE.md`; `apps/mobile/lib/design_system.dart`; current Flutter screens and platform manifests
- Product priority: context-appropriate capture first, minimum intervention second, closure third

## Brand

- Personality: quiet, precise, trustworthy personal tool
- Trust signals: state what was understood, separate confirmed and unresolved facts, never pretend an unread image was analyzed, discard raw captures after analysis
- Avoid: decorative AI effects, dashboard clutter, developer configuration in production, duplicated system settings, custom imitations of native dialogs

## Product goals

- Turn one shared screenshot into the right kind of saved context without re-entry: an appointment, deadline, place, or coupon.
- Complete clear cases in `share -> review -> add` within two or three decisions.
- Ask only for one genuinely unresolved field.
- Let a user confirm an extracted tentative value without making them select it again.
- Keep only the actions and alerts that make the captured context more useful; a saved place must not become a fake schedule.
- Make AI and network failures explicit and recoverable.
- Native sharing must release the user immediately: the Share Extension queues a system-owned background transfer and closes, while the containing app stores only a real server result and reports completion by notification.

## Non-goals

- Multi-image capture in the MVP.
- Always-on background agents.
- Arbitrary surveillance of photos, messages, or calendars.
- Purchases, reservations, and travel automation beyond the focused v2 place/coupon capture flows.
- Cross-Loop semantic inference beyond deterministic, user-reviewable shared-place links.

## Personas and jobs

- Primary personas: people who make plans in messenger conversations; students and workers who receive poster/notice deadlines; people collecting restaurants and time-limited coupons from social feeds
- User jobs: capture an already-agreed plan, resolve the final agreement, add it to the system calendar, save a place for later, protect a coupon expiry, and close the context when done
- Key contexts: coming from a native share sheet, using one hand, limited attention, uncertain connectivity, sensitive screenshots

## Information architecture

- Home: actionable loops grouped by Today, This week, and Date undecided
- Capture: one image or text; native shared content begins analysis immediately and lands in Review or one focused question
- Processing: truthful remote AI state, cancel/retry affordance
- Review: show only facts appropriate to the classified Loop: schedule facts for appointments, due date for deadlines, place facts for saved places, and expiry date for coupons
- Ambiguity: exactly one unresolved fact and one decision
- Detail: useful actions, contextual links, only meaningful checkpoint alerts, Close
- Settings: retention and user-facing behavior; provider/API diagnostics only in debug builds

## Design principles

1. Zero Friction does not mean zero control.
2. The AI produces structured facts; the user reviews instead of filling a form.
3. One screen carries one decision.
4. Never ask for a time when the captured context is not a timed event.
5. Never present fallback text parsing as image understanding.
6. The operating system owns system dialogs, pickers, permissions, calendars, and app settings.
7. A high-confidence result should be calm; uncertainty should be local to the affected field.
8. Analysis is a draft. Persistence starts only after explicit approval.

## Visual language

- Color: white canvas, `#F6F8FB` secondary surface, `#0B1B3A` primary text, `#627086` secondary text, `#E2E8F0` border, `#246BFD` primary action
- Brand mark: a bold white open loop with a single forward point on cobalt blue. Use the same master artwork for iOS, Android, Flutter Web, and the contest-site favicon/header mark.
- Typography: platform-respecting sans serif; strong but compact page titles; native system UI retains the system font
- Spacing/layout rhythm: 8-point grid, 22-24 point page padding, content before marketing copy
- Shape/radius/elevation: 14-16 point app surfaces, minimal elevation, no gradients or AI glow
- Web presentation: one viewport, one product, and one working phone containing the actual Flutter application compiled for the browser. It must never redraw or imitate the mobile UI with HTML. The left side explains the product outcome in one sentence and four compact cards: share, analyze, confirm, and act.
- Motion: only the short startup identity sequence, user-triggered screen navigation, and the bounded analysis progress state may animate. Startup uses a cobalt field where the white loop draws on, its point travels the orbit and settles, then the wordmark reveals before the home screen replaces it. Keep the full sequence under two seconds. Automatic scenario cycling, timed Review/Save advancement, pointer effects, decorative background objects, and fake phase controls are prohibited.
- Imagery/iconography: system icons with accessible labels; no decorative illustration required for core actions

## Components

- Existing components to reuse: facts, loop cards, information banners, action/checkpoint rows
- New/changed components: single-image preview, retryable analysis failure, adaptive destructive confirmation, compact labeled review-title field, typed-time field with picker alternative, confidence-aware field state, plain-language action/checkpoint explanations, relative checkpoint timestamps, kind-aware review facts, and linked-Loop rows
- Contest web components: a local image-based iPhone 16-proportion device frame around the Flutter Web build and a four-step product explanation. The frame stays near 74% of the visible viewport height, includes hardware edges and side controls, uses no decorative strokes over the app surface, and never blocks interaction. All product screens, state, and interactions are owned by the Flutter application inside the frame.
- Embedded Flutter Web preserves a 44-point top inset and a 48-point bottom inset so primary actions remain visibly separated from the Dynamic Island and home indicator inside the device frame.
- Quick confirmation concept remains a production capability, but the contest web prioritizes the complete in-app flow and does not cover the phone with a fake system overlay.
- Variants and states: loading, success, one-field ambiguity, provider failure, offline, disabled, closed
- Token/component ownership: `apps/mobile/lib/design_system.dart` owns visual tokens; platform helpers own adaptive/native presentation

## Platform-native behavior

- Gallery and camera use the operating system's single-image picker.
- Destructive confirmation uses a Cupertino destructive/cancel alert on iOS and the platform Material confirmation on Android.
- Date editing uses the platform picker. A missing or tentative time also accepts direct keyboard entry (`16:30`, `오후 4시 30분`) while retaining the picker as an alternative.
- Calendar creation opens the operating system calendar composer.
- After the first app frame, the operating system notification permission is requested once. When granted, the app automatically schedules future local checkpoint alerts for active Loops.
- External sharing posts a completion notification only after the server result is stored. The same result notification is suppressed while OpenLoop is active because the result screen is already visible.
- On iOS 16.2 or later, an external share may use one transient Live Activity for `분석 중 -> 정리 완료`; Dynamic Island-capable phones render it in the island and other supported surfaces use the system Live Activity presentation. Starting, updating, or rendering failure falls back to the existing completion notification without delaying the share-sheet dismissal.
- The Live Activity contains no screenshot, message text, place, participant, or other sensitive extracted facts. Before completion it shows only generic progress; after completion it shows the reviewed draft title and opens the matching job-scoped Review route when tapped, so concurrent shares cannot open each other's result.
- A denied permission offers a link to the operating system app settings; the app does not recreate settings screens.

## Confidence behavior

- High confidence: show the completed schedule and primary Add action, without raw percentages.
- Medium confidence: mark only the affected field as `확인 필요`.
- Missing fact: ask one question or allow saving an incomplete Open Loop.
- Raw field confidence remains available to debug/QA builds and evaluation reports.

## Lifecycle contract

```text
Capture -> nonpersisted Analysis Draft -> focused review -> approval -> Open Loop -> Close
```

- Leaving Review before approval creates no server Loop.
- Appointment approval saves the Loop, starts the system calendar composer, and returns the app to Home without waiting for the external composer to dismiss.
- Checkpoints are not a to-do list: actions are the user's direct work (calendar, place, checklist), while checkpoints are timed prompts that help with that work.
- An Appointment receives one `T-1h` preparation alert; a Deadline or expiring Coupon receives one `D-1` alert; a saved Place receives none.
- Only future alerts are generated. If the default has passed, use the nearest remaining `T-15m` / `T-5m` appointment alert or a still-useful `D-day` deadline/coupon alert.

## Accessibility

- Target standard: WCAG 2.2 AA-equivalent mobile behavior
- Keyboard/focus behavior: logical title -> facts -> unresolved field -> primary action order
- Contrast/readability: body text 4.5:1; large text and icons 3:1; color is never the only state signal
- Screen-reader semantics: meaningful labels for capture, facts, actions, completion, and destructive actions
- Touch targets: at least 44pt on iOS and 48dp on Android
- Text scaling: no clipping or off-screen primary action at 200%
- Reduced motion and sensory considerations: static processing state when reduced motion is enabled

## Responsive behavior

- Supported devices: current supported Android phones and iPhones, including small screens and Dynamic Type/text scale
- Layout adaptations: scrollable content and safe-area-respecting primary actions
- Touch/hover differences: touch-first; web prototype may add hover without changing information order
- Contest web: desktop is fixed to one viewport with no vertical document scroll. The embedded Flutter web app scales to the available height without clipping. Tablet/mobile stack the same content and may scroll vertically because preserving readable copy and a usable phone viewport takes priority over artificial one-screen compression.
- Viewport filling: the desktop shell must use the actual visible viewport as its containing block and never expose the browser/page background at the right or bottom edge. Validate wide, short, zoomed, tablet, and phone dimensions rather than relying on `100svh` alone.

## Interaction states

- Loading: `대화의 날짜, 시간, 장소를 확인하고 있어요` with cancel support
- Empty: explain native share and offer one-image/text capture
- Error: `이미지를 분석하지 못했어요` with Retry and Use text actions
- Success: structured result and one primary Add action; calendar handoff never leaves the app in a loading state
- Detail: checkpoint times read as `오늘 17:00`, `내일 09:00`, or `8월 20일 (목) 19:00`, never raw ISO timestamps; omit the entire section when no alert is useful
- Disabled: explain the missing prerequisite next to the disabled action
- Offline/slow network: never synthesize a successful image result; preserve the image temporarily and allow retry
- External share: dismiss the Share Extension immediately after the system accepts the background transfer. Completion appears only as a notification; failure preserves the one temporary capture for an in-app retry.
- Live Activity: compact/minimal states show only the OpenLoop mark and progress/completion symbol; the expanded and Lock Screen states use one title, one short status line, and one `결과 보기` affordance. Keep the completed activity visible for about 15 seconds, then end it so the island never becomes persistent clutter.

## Content voice

- Tone: short, factual, warm but not chatty
- Terminology: use `일정 추가`, `장소 저장`, and `쿠폰 저장` according to Loop kind; use `확인 필요` for uncertainty
- Microcopy rules: name the failed operation, avoid provider jargon, never call a deterministic fallback `AI 분석`, and call expiry-only dates `기한` rather than `시간 미정`

## Implementation constraints

- Framework/styling system: Flutter Material app with adaptive Cupertino presentation where the platform owns the interaction
- Contest web framework: existing React + Vite shell with native CSS and an iframe pointing to the same Flutter app compiled under `/app/`. Do not duplicate Flutter state, API calls, sample analyses, or mobile UI in React. No animation dependency or pointer tracking. `prefers-reduced-motion` is required.
- Web API constraint: the Flutter Web build uses a same-origin `/api/*` reverse proxy so browsers never depend on API Gateway preflight behavior. Native platform capabilities that browsers cannot provide remain graceful no-ops or web-specific fallbacks.
- Design-token constraints: extend existing `OLColors` and theme rather than adding another design layer
- Performance constraints: one image, maximum 10MB, no raw capture persistence, bounded remote timeouts
- Compatibility constraints: Android SEND image/text; iOS Share Extension image/text/URL; system calendar and local notifications
- Live Activity constraint: keep the existing iOS 15 app compatibility, gate ActivityKit code at iOS 16.2, provide a dedicated WidgetKit extension, and treat ordinary completion notification delivery as the fallback rather than a second simultaneous success banner.
- Calendar handoff constraint: an OS composer callback may be absent or delayed, so navigation and persistence must not depend on it.
- AI temporal contract: every analysis is grounded in an explicit `Asia/Seoul` reference date/time; a missing year defaults to the reference year unless the phrase itself crosses the year boundary. Appointment requires date/time/place; Deadline requires a date but not a time; Place requires no temporal facts; Coupon may carry an optional expiry date but never requires a time.
- Checkpoint contract: an appointment receives one preparation alert (`T-1h`, or the nearest remaining short lead); a deadline or expiring coupon receives one expiry alert (`D-1`, falling back to the expiry day only when still useful); saved places receive none. Model-supplied explicit checkpoints may add a clearly named user benefit, but generic `T-24h` and post-event prompts are not generated.
- Context-link contract: v2.5 persists only deterministic shared-place links between the same installation's Loops. It does not claim a semantic relationship from vague title similarity.
- AI compute contract: Gemini text analysis uses `MINIMAL` thinking; single-image analysis uses `LOW`; required fields below `0.65` confidence require confirmation
- Quality contract: the checked-in 100-case evaluation must preserve its `20/20/15/15/15/15` scenario distribution and 95% metric gate; the critical reference case must pass every field
- Test/screenshot expectations: real Gemini image evaluation, Android external share, iOS Share Extension embedding/launch, adaptive alert screenshots, 200% text scale

## Open questions

- [ ] Real-device notification permission and delivery need Firebase/APNs credentials before production release.
- [ ] v3 purchase, reservation, and travel Skills need a separate explicit capability contract; do not reuse the v2 classifier as a hidden agent.
- [ ] Production authentication must replace installation-only ownership before a public multi-user launch.
- [ ] Old screenshots containing relative words such as `오늘` need a future capture-date or source-date UX; MVP uses analysis time as the documented reference.
- [ ] FCM, PostHog, and Sentry remain disabled until their credentials and device acceptance checks are complete.
