import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/app.dart';

void main() {
  test('checkpoint timestamps use readable Korean relative dates', () {
    final now = DateTime(2026, 8, 17, 9);

    expect(checkpointTimeText(DateTime(2026, 8, 17, 17), now: now), '오늘 17:00');
    expect(checkpointTimeText(DateTime(2026, 8, 18, 9), now: now), '내일 09:00');
    expect(
      checkpointTimeText(DateTime(2026, 8, 20, 19), now: now),
      '8월 20일 (목) 19:00',
    );
  });
}
