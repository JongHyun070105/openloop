import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/models/open_loop.dart';
import 'package:openloop_mobile/services/checkpoint_planner.dart';

void main() {
  test('same-day appointment omits the stale day-before checkpoint', () {
    final now = DateTime(2026, 8, 17, 11);
    final planned = planCheckpoints(
      kind: LoopKind.appointment,
      title: '저녁 약속',
      eventAt: DateTime(2026, 8, 17, 19),
      now: now,
    );

    expect(planned.map((item) => item.offset), ['T-1h']);
    expect(planned.every((item) => item.dueAt.isAfter(now)), isTrue);
  });

  test('imminent appointment receives the nearest useful prompt', () {
    final now = DateTime(2026, 8, 17, 18, 47);
    final planned = planCheckpoints(
      kind: LoopKind.appointment,
      title: '저녁 약속',
      eventAt: DateTime(2026, 8, 17, 19),
      now: now,
    );

    expect(planned.map((item) => item.offset), ['T-5m']);
    expect(planned.first.dueAt, DateTime(2026, 8, 17, 18, 55));
  });

  test('same-day deadline uses one useful day-of alert', () {
    final now = DateTime(2026, 8, 17, 11);
    final planned = planCheckpoints(
      kind: LoopKind.deadline,
      title: '공모전 마감',
      eventAt: DateTime(2026, 8, 17, 19),
      now: now,
    );

    expect(planned.map((item) => item.offset), ['D-day']);
    expect(planned.single.dueAt, DateTime(2026, 8, 17, 19));
  });

  test('saved place never receives a checkpoint', () {
    final planned = planCheckpoints(
      kind: LoopKind.place,
      title: '난포',
      eventAt: DateTime(2026, 8, 20, 19),
      now: DateTime(2026, 8, 17, 11),
    );

    expect(planned, isEmpty);
  });

  test('coupon receives one expiry alert', () {
    final planned = planCheckpoints(
      kind: LoopKind.coupon,
      title: '커피 쿠폰',
      eventAt: DateTime(2026, 8, 20, 10),
      now: DateTime(2026, 8, 17, 11),
    );

    expect(planned.map((item) => item.offset), ['D-1']);
  });
}
