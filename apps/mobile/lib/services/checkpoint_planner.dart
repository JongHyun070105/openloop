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

/// Produces only checkpoints that can still help the user act.
///
/// A plan made today for a 19:00 appointment must not ask for a "day before"
/// confirmation. When the usual lead times have passed, the nearest useful
/// pre-event prompt replaces them instead of scheduling a stale notification.
List<CheckpointPlan> planCheckpoints({
  required LoopKind kind,
  required String title,
  required DateTime? eventAt,
  DateTime? now,
}) {
  if (eventAt == null) return const [];
  final reference = now ?? DateTime.now();
  final templates = kind == LoopKind.deadline
      ? <({String offset, String label, Duration delta})>[
          (
            offset: 'D-7',
            label: '$title D-7 준비 확인',
            delta: const Duration(days: -7),
          ),
          (
            offset: 'D-3',
            label: '$title D-3 제출물 점검',
            delta: const Duration(days: -3),
          ),
          (
            offset: 'D-1',
            label: '$title D-1 최종 확인',
            delta: const Duration(days: -1),
          ),
        ]
      : <({String offset, String label, Duration delta})>[
          (
            offset: 'T-24h',
            label: '$title 하루 전 확인',
            delta: const Duration(hours: -24),
          ),
          (
            offset: 'T-2h',
            label: '$title 출발·준비 확인',
            delta: const Duration(hours: -2),
          ),
          (
            offset: 'T-1h',
            label: '$title 한 시간 전 준비 확인',
            delta: const Duration(hours: -1),
          ),
          (
            offset: 'T+1d',
            label: '$title 후속 확인',
            delta: const Duration(days: 1),
          ),
        ];

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
    final shortLeadTimes = kind == LoopKind.deadline
        ? <({String offset, String label, Duration delta})>[
            (
              offset: 'T-3h',
              label: '$title 마감 3시간 전 점검',
              delta: const Duration(hours: -3),
            ),
            (
              offset: 'T-1h',
              label: '$title 마감 한 시간 전 확인',
              delta: const Duration(hours: -1),
            ),
            (
              offset: 'T-30m',
              label: '$title 마감 30분 전 확인',
              delta: const Duration(minutes: -30),
            ),
            (
              offset: 'T-5m',
              label: '$title 마감 직전 확인',
              delta: const Duration(minutes: -5),
            ),
          ]
        : <({String offset, String label, Duration delta})>[
            (
              offset: 'T-30m',
              label: '$title 출발 30분 전 확인',
              delta: const Duration(minutes: -30),
            ),
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
