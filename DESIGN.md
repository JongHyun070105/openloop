# Design

## Source of truth

- Status: Active
- Last refreshed: 2026-08-16
- Primary product surfaces: Flutter iOS/Android app, Android share intent, iOS Share Extension
- Evidence reviewed: Notion `OpenLoop 구체화` sections 1-33; attached product screenshots 1-3; `docs/PRODUCT_SCOPE.md`; `docs/ARCHITECTURE.md`; `apps/mobile/lib/design_system.dart`; current Flutter screens and platform manifests
- Product priority: screenshot accuracy first, context resolution and minimum intervention second, closure third

## Brand

- Personality: quiet, precise, trustworthy personal tool
- Trust signals: state what was understood, separate confirmed and unresolved facts, never pretend an unread image was analyzed, discard raw captures after analysis
- Avoid: decorative AI effects, dashboard clutter, developer configuration in production, duplicated system settings, custom imitations of native dialogs

## Product goals

- Turn one shared screenshot into an actionable appointment or deadline without re-entry.
- Complete clear cases in `share -> review -> add` within two or three decisions.
- Ask only for one genuinely unresolved field.
- Keep the loop active through calendar/reminder/checkpoint actions until completion.
- Make AI and network failures explicit and recoverable.

## Non-goals

- Multi-image capture in the MVP.
- Always-on background agents.
- Arbitrary surveillance of photos, messages, or calendars.
- Purchase, travel, coupon, billing, or collaborative skills before the personal Appointment + Deadline loop is reliable.

## Personas and jobs

- Primary personas: people who make plans in messenger conversations; students and workers who receive poster/notice deadlines
- User jobs: capture an already-agreed plan, resolve the final agreement, add it to the system calendar, remember preparation work, close it when done
- Key contexts: coming from a native share sheet, using one hand, limited attention, uncertain connectivity, sensitive screenshots

## Information architecture

- Home: actionable loops grouped by Today, This week, and Date undecided
- Capture: one image or text; native shared content enters here with one preview
- Processing: truthful remote AI state, cancel/retry affordance
- Review: title, date, time, place, reminder, and one primary action
- Ambiguity: exactly one unresolved fact and one decision
- Detail: actions, checklist, contextual checkpoints, Close
- Settings: retention and user-facing behavior; provider/API diagnostics only in debug builds

## Design principles

1. Zero Friction does not mean zero control.
2. The AI produces structured facts; the user reviews instead of filling a form.
3. One screen carries one decision.
4. Never ask again for a fact the source states clearly.
5. Never present fallback text parsing as image understanding.
6. The operating system owns system dialogs, pickers, permissions, calendars, and app settings.
7. A high-confidence result should be calm; uncertainty should be local to the affected field.
8. Analysis is a draft. Persistence starts only after explicit approval.

## Visual language

- Color: white canvas, `#F6F8FB` secondary surface, `#0B1B3A` primary text, `#627086` secondary text, `#E2E8F0` border, `#246BFD` primary action
- Typography: platform-respecting sans serif; strong but compact page titles; native system UI retains the system font
- Spacing/layout rhythm: 8-point grid, 22-24 point page padding, content before marketing copy
- Shape/radius/elevation: 14-16 point app surfaces, minimal elevation, no gradients or AI glow
- Motion: one short processing transition; reduced-motion users receive a static progress state
- Imagery/iconography: system icons with accessible labels; no decorative illustration required for core actions

## Components

- Existing components to reuse: facts, loop cards, information banners, action/checkpoint rows
- New/changed components: single-image preview, retryable analysis failure, adaptive destructive confirmation, tappable review fact row, confidence-aware field state
- Variants and states: loading, success, one-field ambiguity, provider failure, offline, disabled, closed
- Token/component ownership: `apps/mobile/lib/design_system.dart` owns visual tokens; platform helpers own adaptive/native presentation

## Platform-native behavior

- Gallery and camera use the operating system's single-image picker.
- Destructive confirmation uses a Cupertino destructive/cancel alert on iOS and the platform Material confirmation on Android.
- Date and time editing use the platform picker.
- Calendar creation opens the operating system calendar composer.
- Notification permission is requested only at the moment the user enables a reminder.
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
- Appointment approval saves the Loop and opens the system calendar composer as the same primary flow.
- Default Appointment checkpoints: `T-24h`, `T-2h`, `T-1h`, `T+1d`.
- Default Deadline checkpoints: `D-7`, `D-3`, `D-1`.

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

## Interaction states

- Loading: `대화의 날짜, 시간, 장소를 확인하고 있어요` with cancel support
- Empty: explain native share and offer one-image/text capture
- Error: `이미지를 분석하지 못했어요` with Retry and Use text actions
- Success: structured result and one primary Add action
- Disabled: explain the missing prerequisite next to the disabled action
- Offline/slow network: never synthesize a successful image result; preserve the image temporarily and allow retry

## Content voice

- Tone: short, factual, warm but not chatty
- Terminology: Capture, Open Loop, Loop Closed; use `확인 필요` for uncertainty
- Microcopy rules: name the failed operation, avoid provider jargon, never call a deterministic fallback `AI 분석`

## Implementation constraints

- Framework/styling system: Flutter Material app with adaptive Cupertino presentation where the platform owns the interaction
- Design-token constraints: extend existing `OLColors` and theme rather than adding another design layer
- Performance constraints: one image, maximum 10MB, no raw capture persistence, bounded remote timeouts
- Compatibility constraints: Android SEND image/text; iOS Share Extension image/text/URL; system calendar and local notifications
- AI temporal contract: every analysis is grounded in an explicit `Asia/Seoul` reference date/time; a missing year defaults to the reference year unless the phrase itself crosses the year boundary
- AI compute contract: Gemini text analysis uses `MINIMAL` thinking; single-image analysis uses `LOW`; required fields below `0.65` confidence require confirmation
- Quality contract: the checked-in 100-case evaluation must preserve its `20/20/15/15/15/15` scenario distribution and 95% metric gate; the critical reference case must pass every field
- Test/screenshot expectations: real Gemini image evaluation, Android external share, iOS Share Extension embedding/launch, adaptive alert screenshots, 200% text scale

## Open questions

- [ ] Real-device notification permission and delivery need Firebase/APNs credentials before production release.
- [ ] Production authentication must replace installation-only ownership before a public multi-user launch.
- [ ] Old screenshots containing relative words such as `오늘` need a future capture-date or source-date UX; MVP uses analysis time as the documented reference.
- [ ] FCM, PostHog, and Sentry remain disabled until their credentials and device acceptance checks are complete.
