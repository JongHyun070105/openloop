import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/main.dart';

void main() {
  testWidgets('shows loop overview and capture inputs', (tester) async {
    await tester.pumpWidget(const OpenLoopApp());

    expect(find.text('난포 저녁 약속'), findsOneWidget);
    expect(find.text('AI 공모전 제출'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();

    expect(find.text('OpenLoop에 공유'), findsOneWidget);
    expect(find.text('스크린샷'), findsOneWidget);
    expect(find.text('이미지'), findsOneWidget);
    expect(find.text('텍스트'), findsOneWidget);
  });
}
