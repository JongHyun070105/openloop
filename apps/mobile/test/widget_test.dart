import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/app.dart';
import 'package:openloop_mobile/app_controller.dart';
import 'package:openloop_mobile/models/open_loop.dart';
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
    await tester.pumpWidget(OpenLoopApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('아직 Open Loop가 없습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();
    expect(find.text('OpenLoop에 공유'), findsOneWidget);
    expect(find.text('카메라'), findsOneWidget);
    expect(find.text('사진·스크린샷'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('capture-text')),
      'AI 공모전 제출 마감 8월 22일 23시',
    );
    await tester.tap(find.byKey(const Key('analyze-button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('DEADLINE'), findsOneWidget);
    expect(find.text('API가 연결되지 않아 로컬 데모 분석을 사용했습니다.'), findsOneWidget);
    expect(find.text('AI 요약'), findsOneWidget);
    expect(find.text('AI 확신도'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-loop-button')),
      220,
    );
    await tester.tap(find.byKey(const Key('save-loop-button')));
    await tester.pumpAndSettle();

    expect(find.text('공모전 마감'), findsOneWidget);
    await tester.tap(find.text('공모전 마감'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('실행 항목'), 180);
    expect(find.text('실행 항목'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('체크포인트'), 180);
    expect(find.text('체크포인트'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('캘린더에 추가'), 180);
    await tester.tap(find.text('캘린더에 추가'));
    await tester.pumpAndSettle();
    expect(
      controller.loops.single.actions
          .where((action) => action.type == 'calendar')
          .single
          .completed,
      isTrue,
    );

    await tester.scrollUntilVisible(find.text('공모전 마감 D-7 준비 확인'), 180);
    await tester.tap(find.text('공모전 마감 D-7 준비 확인'));
    await tester.pumpAndSettle();
    expect(controller.loops.single.checkpoints.first.completed, isTrue);
  });

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
    final loop = OpenLoop(
      id: 'needs-input',
      kind: LoopKind.appointment,
      state: LoopState.needsInput,
      title: '저녁 약속',
      source: 'text',
      createdAt: DateTime(2026, 8, 16),
      date: DateTime(2026, 8, 17),
      time: '19:00:00',
      missingFields: const ['place', 'participants'],
      confidence: const {},
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
      'T+1d',
    ]);
    expect(controller.loops.single.id, loop.id);
  });

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
