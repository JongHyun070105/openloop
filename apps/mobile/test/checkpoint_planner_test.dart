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

    expect(planned.map((item) => item.offset), ['T-2h', 'T-1h', 'T+1d']);
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

    expect(planned.map((item) => item.offset), ['T-5m', 'T+1d']);
    expect(planned.first.dueAt, DateTime(2026, 8, 17, 18, 55));
  });

  test(
    'same-day deadline replaces missed day cadence with a useful lead time',
    () {
      final now = DateTime(2026, 8, 17, 11);
      final planned = planCheckpoints(
        kind: LoopKind.deadline,
        title: '공모전 마감',
        eventAt: DateTime(2026, 8, 17, 19),
        now: now,
      );

      expect(planned.map((item) => item.offset), ['T-3h']);
      expect(planned.single.dueAt, DateTime(2026, 8, 17, 16));
    },
  );
}
