import '../models/open_loop.dart';

class CheckpointPlan {
  const CheckpointPlan({
    required this.offset,
    required this.title,
    required this.dueAt,
  });

  final String offset;
  final String title;
  final DateTime dueAt;
}

/// Produces one contextual alert only when the capture has a real time or
/// expiry. Saved places deliberately produce no checkpoint at all.
List<CheckpointPlan> planCheckpoints({
  required LoopKind kind,
  required String title,
  required DateTime? eventAt,
  DateTime? now,
}) {
  if (eventAt == null || kind == LoopKind.place) return const [];
  final reference = now ?? DateTime.now();
  final templates = switch (kind) {
    LoopKind.appointment => <({String offset, String label, Duration delta})>[
      (
        offset: 'T-1h',
        label: '$title 출발·준비 확인',
        delta: const Duration(hours: -1),
      ),
    ],
    LoopKind.deadline => <({String offset, String label, Duration delta})>[
      (offset: 'D-1', label: '$title 전날 확인', delta: const Duration(days: -1)),
    ],
    LoopKind.coupon => <({String offset, String label, Duration delta})>[
      (
        offset: 'D-1',
        label: '$title 기한 전날 확인',
        delta: const Duration(days: -1),
      ),
    ],
    LoopKind.place => const <({String offset, String label, Duration delta})>[],
  };

  final planned = <CheckpointPlan>[
    for (final template in templates)
      if (eventAt.add(template.delta).isAfter(reference))
        CheckpointPlan(
          offset: template.offset,
          title: template.label,
          dueAt: eventAt.add(template.delta),
        ),
  ];

  final hasUpcomingPreparation = planned.any(
    (item) => item.dueAt.isBefore(eventAt),
  );
  if (!hasUpcomingPreparation && eventAt.isAfter(reference)) {
    final shortLeadTimes = kind == LoopKind.appointment
        ? <({String offset, String label, Duration delta})>[
            (
              offset: 'T-15m',
              label: '$title 출발 15분 전 확인',
              delta: const Duration(minutes: -15),
            ),
            (
              offset: 'T-5m',
              label: '$title 출발 직전 확인',
              delta: const Duration(minutes: -5),
            ),
          ]
        : <({String offset, String label, Duration delta})>[
            (offset: 'D-day', label: '$title 기한 당일 확인', delta: Duration.zero),
          ];
    for (final template in shortLeadTimes) {
      final dueAt = eventAt.add(template.delta);
      if (!dueAt.isAfter(reference)) continue;
      planned.add(
        CheckpointPlan(
          offset: template.offset,
          title: template.label,
          dueAt: dueAt,
        ),
      );
      break;
    }
  }

  planned.sort((left, right) => left.dueAt.compareTo(right.dueAt));
  return planned;
}
