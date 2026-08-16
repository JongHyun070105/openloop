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
    expect(find.text('스크린샷'), findsOneWidget);
    expect(find.text('이미지'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('save-loop-button')));
    await tester.pumpAndSettle();

    expect(find.text('공모전 마감'), findsOneWidget);
    await tester.tap(find.text('공모전 마감'));
    await tester.pumpAndSettle();
    expect(find.text('캘린더에 추가'), findsOneWidget);
    expect(find.text('알림 예약'), findsOneWidget);
    await tester.tap(find.byKey(const Key('close-loop-button')));
    await tester.pumpAndSettle();
    expect(find.text('닫힌 Loop'), findsOneWidget);
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
    expect(controller.loops.single.id, loop.id);
  });
}
