import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/app.dart';
import 'package:openloop_mobile/app_controller.dart';
import 'package:openloop_mobile/models/open_loop.dart';
import 'package:openloop_mobile/services/analyze_service.dart';
import 'package:openloop_mobile/services/device_actions.dart';
import 'package:openloop_mobile/services/loop_repository.dart';

void main() {
  late MemoryLoopRepository repository;
  late AppController controller;

  setUp(() {
    repository = MemoryLoopRepository();
    controller = AppController(
      repository: repository,
      deviceActions: NoopDeviceActions(),
      defaultBaseUrl: '',
    );
  });

  testWidgets('captures, analyzes, saves, details, and closes a deadline', (
    tester,
  ) async {
    final future = DateTime.now().add(const Duration(days: 14));
    final date =
        '${future.year}-${future.month.toString().padLeft(2, '0')}-${future.day.toString().padLeft(2, '0')}';
    await tester.pumpWidget(OpenLoopApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('아직 Open Loop가 없습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();
    expect(find.text('일정 추가'), findsOneWidget);
    expect(find.text('카메라'), findsOneWidget);
    expect(find.text('사진·스크린샷'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('capture-text')),
      'AI 공모전 제출 마감 $date 23시',
    );
    await tester.tap(find.byKey(const Key('analyze-button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('DEADLINE'), findsOneWidget);
    expect(find.text('원격 AI를 설정하지 않아 로컬 규칙 분석을 사용했습니다.'), findsOneWidget);
    expect(find.text('AI 요약'), findsOneWidget);
    for (
      var attempt = 0;
      attempt < 4 &&
          find.byKey(const Key('save-loop-button')).evaluate().isEmpty;
      attempt++
    ) {
      await tester.dragFrom(const Offset(200, 550), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('save-loop-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-loop-button')));
    await tester.pumpAndSettle();

    expect(find.text('공모전 마감'), findsOneWidget);
    await tester.tap(find.text('공모전 마감'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('실행 항목'), 180);
    expect(find.text('실행 항목'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('체크포인트'), 180);
    expect(find.text('체크포인트'), findsOneWidget);

    final calendarButton = find.byKey(const Key('calendar-add-button'));
    await tester.ensureVisible(calendarButton);
    await tester.pumpAndSettle();
    await tester.tap(calendarButton);
    await tester.pumpAndSettle();
    expect(
      controller.loops.single.actions
          .where((action) => action.type == 'calendar')
          .single
          .completed,
      isTrue,
    );

    final checkpoint = find.text('공모전 마감 D-7 준비 확인');
    await tester.ensureVisible(checkpoint);
    await tester.pumpAndSettle();
    await tester.tap(checkpoint);
    await tester.pumpAndSettle();
    expect(controller.loops.single.checkpoints.first.completed, isTrue);
  });

  testWidgets(
    'first app frame asks for notification permission and syncs future loops',
    (tester) async {
      final deviceActions = _RecordingDeviceActions();
      final future = DateTime.now().add(const Duration(days: 2));
      repository.loops = [
        OpenLoop(
          id: 'notification-loop',
          kind: LoopKind.appointment,
          state: LoopState.open,
          title: '회의',
          source: 'text',
          createdAt: DateTime.now(),
          date: DateTime(future.year, future.month, future.day),
          time: '19:00:00',
          checkpoints: [
            LoopCheckpoint(
              id: 'checkpoint',
              offset: 'T-1h',
              title: '회의 한 시간 전 준비 확인',
              dueAt: DateTime(future.year, future.month, future.day, 18),
            ),
          ],
          confidence: const {},
        ),
      ];
      controller = AppController(
        repository: repository,
        deviceActions: deviceActions,
        defaultBaseUrl: '',
      );

      await tester.pumpWidget(OpenLoopApp(controller: controller));
      await tester.pumpAndSettle();

      expect(deviceActions.notificationPermissionCalls, 1);
      expect(deviceActions.reminderSyncCalls, 1);
      expect(deviceActions.lastSyncedLoopIds, ['notification-loop']);
    },
  );

  testWidgets('settings persist base URL and retention choice', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(OpenLoopApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('base-url-field')),
      'https://api.openloop.test/',
    );
    await tester.tap(find.text('30일 후 삭제'));
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(repository.baseUrl, 'https://api.openloop.test/');
    expect(repository.retention.name, 'thirtyDays');
  });

  test('resolves every missing field before showing the review', () async {
    final future = DateTime.now().add(const Duration(days: 14));
    final loop = OpenLoop(
      id: 'needs-input',
      kind: LoopKind.appointment,
      state: LoopState.needsInput,
      title: '저녁 약속',
      source: 'text',
      createdAt: DateTime.now(),
      date: DateTime(future.year, future.month, future.day),
      time: '19:00:00',
      missingFields: const ['place', 'participants'],
      confidence: const {},
      persistence: LoopPersistence.remoteDraft,
    );
    final placeResolved = await controller.resolveAmbiguity(
      loop,
      field: 'place',
      value: '성수',
    );
    expect(placeResolved.state, LoopState.needsInput);
    expect(placeResolved.missingFields, const ['participants']);

    final complete = await controller.resolveAmbiguity(
      placeResolved,
      field: 'participants',
      value: const ['나', '친구'],
    );
    expect(complete.state, LoopState.open);
    expect(complete.place, '성수');
    expect(complete.participants, const ['나', '친구']);
    expect(complete.summary, contains('성수'));
    expect(complete.summary, isNot(contains('확인이 필요합니다')));
    expect(complete.actions.any((item) => item.type == 'place'), isTrue);
    expect(complete.checkpoints.map((item) => item.offset), [
      'T-24h',
      'T-2h',
      'T-1h',
      'T+1d',
    ]);
    expect(controller.loops, isEmpty);
    expect(repository.loops, isEmpty);
  });

  test('remote analysis and ambiguity remain drafts until approval', () async {
    final api = _RecordingLoopApi();
    final draftController = AppController(
      repository: repository,
      deviceActions: NoopDeviceActions(),
      defaultBaseUrl: 'https://api.example',
      apiFactory: (_) => api,
    );
    await draftController.initialize();

    final draft = await draftController.analyze(
      text: '오늘 4시 종로5가역 12번 출구 향수 거래',
      source: 'text',
    );
    final resolved = await draftController.resolveAmbiguity(
      draft.copyWith(
        state: LoopState.needsInput,
        missingFields: const ['place'],
      ),
      field: 'place',
      value: '종로5가역 12번 출구',
    );

    expect(api.analyzeCalls, 1);
    expect(api.ambiguityCalls, 0);
    expect(resolved.persistence, LoopPersistence.remoteDraft);
    expect(draftController.loops, isEmpty);
    expect(repository.loops, isEmpty);
  });

  test('review edits update the draft without persisting it', () async {
    final draft = _remoteDraft();

    final title = controller.editDraft(draft, field: 'title', value: '향수 직거래');
    final date = controller.editDraft(
      title,
      field: 'date',
      value: '2026-08-17',
    );
    final time = controller.editDraft(
      date,
      field: 'start_time',
      value: '17:30:00',
    );
    final place = controller.editDraft(
      time,
      field: 'place',
      value: '동대문역 1번 출구',
    );

    expect(place.title, '향수 직거래');
    expect(place.date, DateTime(2026, 8, 17));
    expect(place.time, '17:30:00');
    expect(place.place, '동대문역 1번 출구');
    expect(place.summary, contains('동대문역 1번 출구'));
    expect(repository.loops, isEmpty);
  });

  test('image analysis never falls back to a text-only local result', () async {
    await controller.initialize();

    await expectLater(
      controller.analyzeImage(imagePath: '/tmp/capture.png'),
      throwsA(isA<StateError>()),
    );
    expect(controller.lastAnalysisWasLocal, isFalse);
    expect(controller.loops, isEmpty);
  });

  test(
    'configured text AI failure stays retryable instead of using a local demo',
    () async {
      final remoteController = AppController(
        repository: repository,
        deviceActions: NoopDeviceActions(),
        defaultBaseUrl: 'https://api.example',
        apiFactory: (_) => _FailingLoopApi(),
      );
      await remoteController.initialize();

      await expectLater(
        remoteController.analyze(text: '오후 7시 약속', source: 'text'),
        throwsA(isA<StateError>()),
      );
      expect(remoteController.lastAnalysisWasLocal, isFalse);
      expect(remoteController.loops, isEmpty);
    },
  );

  testWidgets('uses the server suggested question in the ambiguity UI', (
    tester,
  ) async {
    final loop = OpenLoop(
      id: 'question-loop',
      kind: LoopKind.appointment,
      state: LoopState.needsInput,
      title: '회의',
      source: 'image',
      createdAt: DateTime(2026, 8, 16),
      missingFields: const ['place'],
      suggestedQuestion: '이미지 속 어느 지점을 장소로 등록할까요?',
      confidence: const {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AmbiguityScreen(controller: controller, loop: loop),
      ),
    );

    expect(find.text('이미지 속 어느 지점을 장소로 등록할까요?'), findsOneWidget);
  });

  testWidgets(
    'a tentative extracted date can be confirmed without selecting it again',
    (tester) async {
      final loop = OpenLoop(
        id: 'tentative-date',
        kind: LoopKind.appointment,
        state: LoopState.needsInput,
        title: '저녁 약속',
        source: 'image',
        createdAt: DateTime(2026, 8, 16),
        date: DateTime(2026, 8, 20),
        missingFields: const ['date'],
        confidence: const {'date': .4},
        persistence: LoopPersistence.remoteDraft,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AmbiguityScreen(controller: controller, loop: loop),
        ),
      );

      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ambiguity-continue-button')),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('추출한 날짜가 맞으면 바로 다음으로 넘어갈 수 있어요.'), findsOneWidget);
    },
  );

  testWidgets('a missing time accepts direct keyboard input', (tester) async {
    final loop = OpenLoop(
      id: 'typed-time',
      kind: LoopKind.appointment,
      state: LoopState.needsInput,
      title: '회의',
      source: 'text',
      createdAt: DateTime(2026, 8, 16),
      date: DateTime(2026, 8, 20),
      missingFields: const ['start_time'],
      confidence: const {},
      persistence: LoopPersistence.remoteDraft,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AmbiguityScreen(controller: controller, loop: loop),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('ambiguity-continue-button')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('ambiguity-time-input')),
      '오후 4시 30분',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('ambiguity-continue-button')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('ambiguity-continue-button')));
    await tester.pumpAndSettle();
    expect(find.text('분석 결과'), findsOneWidget);
    expect(find.text('16:30'), findsOneWidget);
  });

  test('normalizes compact manual time input', () {
    expect(normalizeTimeInput('16:30'), '16:30:00');
    expect(normalizeTimeInput('오후 4시 30분'), '16:30:00');
    expect(normalizeTimeInput('930'), '09:30:00');
    expect(normalizeTimeInput('25:00'), isNull);
  });

  testWidgets('shared capture starts analysis without a second tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureScreen(
          controller: controller,
          initialText: 'AI 공모전 제출 마감 8월 22일 23시',
          autoAnalyze: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('DEADLINE'), findsOneWidget);
  });

  testWidgets('appointment primary review action saves and opens calendar', (
    tester,
  ) async {
    final deviceActions = _RecordingDeviceActions();
    final appointmentController = AppController(
      repository: repository,
      deviceActions: deviceActions,
      defaultBaseUrl: '',
    );
    final loop = OpenLoop(
      id: 'review-calendar',
      kind: LoopKind.appointment,
      state: LoopState.open,
      title: '성수 회의',
      source: 'image',
      createdAt: DateTime(2026, 8, 16),
      date: DateTime(2026, 8, 16),
      time: '19:00:00',
      actions: const [
        LoopAction(id: 'calendar', type: 'calendar', title: '일정 추가'),
      ],
      confidence: const {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReviewScreen(controller: appointmentController, loop: loop),
      ),
    );
    await tester.tap(find.byKey(const Key('save-loop-button')));
    await tester.pumpAndSettle();

    expect(deviceActions.calendarCalls, 1);
    expect(repository.loops.single.id, loop.id);
    expect(repository.loops.single.actions.single.completed, isTrue);
  });

  testWidgets('calendar retry never creates the reviewed server loop twice', (
    tester,
  ) async {
    final api = _RecordingLoopApi();
    final deviceActions = _RecordingDeviceActions(calendarResult: false);
    final draftController = AppController(
      repository: repository,
      deviceActions: deviceActions,
      defaultBaseUrl: 'https://api.example',
      apiFactory: (_) => api,
    );
    await draftController.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: ReviewScreen(controller: draftController, loop: _remoteDraft()),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장하고 캘린더 열기'));
    await tester.pumpAndSettle();
    expect(find.text('캘린더 다시 열기'), findsOneWidget);
    await tester.tap(find.text('캘린더 다시 열기'));
    await tester.pumpAndSettle();

    expect(api.createCalls, 1);
    expect(deviceActions.calendarCalls, 2);
    expect(repository.loops.single.id, 'persisted-loop');
    expect(repository.loops.single.persistence, LoopPersistence.persisted);
  });

  testWidgets(
    'calendar composer callback cannot leave the review in a loading state',
    (tester) async {
      final deviceActions = _HangingDeviceActions();
      final appointmentController = AppController(
        repository: repository,
        deviceActions: deviceActions,
        defaultBaseUrl: '',
      );
      final loop = OpenLoop(
        id: 'calendar-handoff',
        kind: LoopKind.appointment,
        state: LoopState.open,
        title: '성수 회의',
        source: 'image',
        createdAt: DateTime(2026, 8, 16),
        date: DateTime(2026, 8, 20),
        time: '19:00:00',
        actions: const [
          LoopAction(id: 'calendar', type: 'calendar', title: '일정 추가'),
        ],
        confidence: const {},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ReviewScreen(controller: appointmentController, loop: loop),
        ),
      );
      await tester.tap(find.byKey(const Key('save-loop-button')));
      await tester.pumpAndSettle();

      expect(deviceActions.calendarCalls, 1);
      expect(repository.loops.single.id, loop.id);
      expect(find.text('저장 중…'), findsNothing);
      expect(find.text('캘린더 다시 열기'), findsOneWidget);
    },
  );

  test(
    'native calendar handoff has a bounded fallback for a missing callback',
    () async {
      final pending = Completer<bool>();
      final actions = NativeDeviceActions(
        calendarLauncher: (_) => pending.future,
        calendarHandoffTimeout: Duration.zero,
      );
      final loop = OpenLoop(
        id: 'calendar-timeout',
        kind: LoopKind.appointment,
        state: LoopState.open,
        title: '회의',
        source: 'text',
        createdAt: DateTime(2026, 8, 16),
        date: DateTime(2026, 8, 20),
        time: '19:00:00',
        confidence: const {},
      );

      expect(await actions.addToCalendar(loop), isTrue);
    },
  );

  testWidgets(
    'delete confirmation follows the current platform',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdaptiveDeleteConfirmation(context),
              child: const Text('삭제 열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('삭제 열기'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('취소'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test(
    'high confidence is hidden in production but low confidence is visible',
    () {
      expect(
        shouldShowConfidence(const {'date': .95, 'time': .9}, debug: false),
        isFalse,
      );
      expect(
        shouldShowConfidence(const {'date': .95, 'time': .6}, debug: false),
        isTrue,
      );
    },
  );

  test('completes actions and deletes loops locally', () async {
    final loop = OpenLoop(
      id: 'action-loop',
      kind: LoopKind.appointment,
      state: LoopState.open,
      title: '캘린더 추가',
      source: 'text',
      createdAt: DateTime(2026, 8, 16),
      date: DateTime(2026, 8, 17),
      time: '19:00:00',
      actions: const [
        LoopAction(id: 'calendar', type: 'calendar', title: '일정 추가'),
      ],
      confidence: const {},
    );
    await controller.saveLoop(loop);

    await controller.updateAction(loop, loop.actions.single, true);
    expect(repository.loops.single.actions.single.completed, isTrue);

    final checklistLoop = OpenLoop(
      id: 'checklist-loop',
      kind: LoopKind.deadline,
      state: LoopState.open,
      title: '제출',
      source: 'text',
      createdAt: DateTime(2026, 8, 16),
      actions: const [
        LoopAction(id: 'checklist', type: 'checklist', title: '제출물 확인'),
      ],
      checklist: const [LoopChecklistItem(id: 'required', title: '파일 업로드')],
      confidence: const {},
    );
    await controller.saveLoop(checklistLoop);
    await controller.updateChecklist(
      checklistLoop,
      checklistLoop.checklist.single,
      true,
    );
    expect(
      controller.loops
          .firstWhere((item) => item.id == checklistLoop.id)
          .actions
          .single
          .completed,
      isTrue,
    );

    await controller.deleteLoop(
      repository.loops.firstWhere((item) => item.id == loop.id),
    );
    expect(repository.loops, hasLength(1));
    expect(controller.loops, hasLength(1));
    expect(repository.loops.single.id, checklistLoop.id);
  });

  test(
    'Close & Forget starts its retention clock when a loop is completed',
    () async {
      final oldLoop = OpenLoop(
        id: 'retention-loop',
        kind: LoopKind.appointment,
        state: LoopState.open,
        title: '오래된 일정',
        source: 'text',
        createdAt: DateTime.now().subtract(const Duration(days: 90)),
        confidence: const {},
      );
      await controller.saveLoop(oldLoop);

      await controller.closeLoop(oldLoop);

      final closed = controller.loops.single;
      expect(closed.state, LoopState.closed);
      expect(closed.completedAt, isNotNull);
      expect(closed.deleteAt, isNotNull);
      expect(closed.deleteAt!.difference(closed.completedAt!).inDays, 7);
    },
  );
}

OpenLoop _remoteDraft() => OpenLoop(
  id: 'draft-loop',
  kind: LoopKind.appointment,
  state: LoopState.open,
  title: '향수 거래',
  source: 'image',
  createdAt: DateTime(2026, 8, 16),
  date: DateTime(2026, 8, 16),
  time: '16:00:00',
  place: '종로5가역 12번 출구',
  confidence: const {'date': .98, 'time': .98, 'location': .98, 'title': .9},
  persistence: LoopPersistence.remoteDraft,
);

class _RecordingLoopApi implements LoopApi {
  int analyzeCalls = 0;
  int createCalls = 0;
  int ambiguityCalls = 0;

  @override
  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async {
    analyzeCalls += 1;
    return _remoteDraft();
  }

  @override
  Future<OpenLoop> analyzeImage({
    required String imagePath,
    String? companionText,
    String source = 'image',
  }) async => _remoteDraft();

  @override
  Future<OpenLoop> createLoop({
    required OpenLoop draft,
    required String retention,
  }) async {
    createCalls += 1;
    return draft.copyWith(
      id: 'persisted-loop',
      persistence: LoopPersistence.persisted,
      actions: const [
        LoopAction(id: 'persisted-calendar', type: 'calendar', title: '일정 추가'),
      ],
    );
  }

  @override
  Future<OpenLoop> resolveAmbiguity({
    required String loopId,
    required String field,
    required Object value,
  }) async {
    ambiguityCalls += 1;
    return _remoteDraft().copyWith(persistence: LoopPersistence.persisted);
  }

  @override
  Future<OpenLoop> complete({
    required String loopId,
    required String retention,
  }) async => _remoteDraft().copyWith(persistence: LoopPersistence.persisted);

  @override
  Future<OpenLoop> updateAction({
    required String loopId,
    required String itemId,
    required bool completed,
  }) async => _remoteDraft().copyWith(
    id: loopId,
    persistence: LoopPersistence.persisted,
    actions: [
      LoopAction(
        id: itemId,
        type: 'calendar',
        title: '일정 추가',
        completed: completed,
      ),
    ],
  );

  @override
  Future<OpenLoop> updateChecklist({
    required String loopId,
    required String itemId,
    required bool completed,
  }) async => _remoteDraft().copyWith(
    id: loopId,
    persistence: LoopPersistence.persisted,
  );

  @override
  Future<OpenLoop> updateCheckpoint({
    required String loopId,
    required String itemId,
    required bool completed,
  }) async => _remoteDraft().copyWith(
    id: loopId,
    persistence: LoopPersistence.persisted,
  );

  @override
  Future<void> deleteLoop({required String loopId}) async {}
}

class _FailingLoopApi extends _RecordingLoopApi {
  @override
  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async => throw StateError('provider unavailable');
}

class _RecordingDeviceActions implements DeviceActions {
  _RecordingDeviceActions({this.calendarResult = true});

  final bool calendarResult;
  int calendarCalls = 0;
  int notificationPermissionCalls = 0;
  int reminderSyncCalls = 0;
  List<String> lastSyncedLoopIds = const [];

  @override
  Future<bool> addToCalendar(OpenLoop loop) async {
    calendarCalls += 1;
    return calendarResult;
  }

  @override
  Future<void> cancelReminders(OpenLoop loop) async {}

  @override
  Future<bool> requestNotificationPermission() async {
    notificationPermissionCalls += 1;
    return true;
  }

  @override
  Future<bool> syncReminders(Iterable<OpenLoop> loops) async {
    reminderSyncCalls += 1;
    lastSyncedLoopIds = loops.map((loop) => loop.id).toList();
    return true;
  }

  @override
  Future<bool> scheduleReminder(OpenLoop loop) async => true;
}

class _HangingDeviceActions implements DeviceActions {
  final _calendarResult = Completer<bool>();
  int calendarCalls = 0;

  @override
  Future<bool> addToCalendar(OpenLoop loop) {
    calendarCalls += 1;
    return _calendarResult.future;
  }

  @override
  Future<void> cancelReminders(OpenLoop loop) async {}

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> syncReminders(Iterable<OpenLoop> loops) async => true;

  @override
  Future<bool> scheduleReminder(OpenLoop loop) async => true;
}
