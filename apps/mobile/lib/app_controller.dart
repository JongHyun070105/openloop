import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import 'config.dart';
import 'models/open_loop.dart';
import 'services/analyze_service.dart';
import 'services/checkpoint_planner.dart';
import 'services/device_actions.dart';
import 'services/external_integrations.dart';
import 'services/loop_repository.dart';

typedef LoopApiFactory = LoopApi Function(String baseUrl);

class AppController extends ChangeNotifier {
  AppController({
    required this.repository,
    required this.deviceActions,
    String defaultBaseUrl = configuredOpenLoopApiBaseUrl,
    LoopApiFactory? apiFactory,
  }) : _defaultBaseUrl = defaultBaseUrl,
       _apiFactory = apiFactory ?? ((url) => ApiAnalyzeService(baseUrl: url));

  final LoopRepository repository;
  final DeviceActions deviceActions;
  final String _defaultBaseUrl;
  final LoopApiFactory _apiFactory;
  final Map<String, Future<OpenLoop>> _approvalInFlight = {};
  final Map<String, OpenLoop> _approvedDrafts = {};

  LoopApi get _api => _apiFactory(baseUrl.trim());

  List<OpenLoop> loops = [];
  String baseUrl = '';
  RetentionPolicy retention = RetentionPolicy.sevenDays;
  ThemeMode themeMode = ThemeMode.light;
  bool ready = false;
  bool processing = false;
  bool lastAnalysisWasLocal = false;
  RemoteCapabilities? capabilities;
  bool capabilitiesLoading = false;

  Future<void> updateThemeMode(ThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    notifyListeners();
    await repository.saveThemeMode(mode);
  }

  Future<void> initialize() async {
    final loaded = await repository.load();
    loops = loaded.map((loop) {
      final textCheck = '${loop.title} ${loop.purpose ?? ''}';
      if ((loop.kind == LoopKind.deadline ||
              loop.kind == LoopKind.appointment) &&
          [
            '뿌링클',
            '기프티콘',
            '기프티쇼',
            '교환권',
            '모바일상품권',
            '상품권',
            '모바일쿠폰',
            '깊티',
            '쿠폰',
          ].any(textCheck.contains)) {
        return loop.copyWith(
          kind: LoopKind.coupon,
          time: null,
          expiresOn: loop.expiresOn ?? loop.date,
          date: null,
        );
      }
      return loop;
    }).toList();
    baseUrl = (await repository.loadBaseUrl()) ?? _defaultBaseUrl;
    retention = await repository.loadRetention();
    themeMode = await repository.loadThemeMode();
    _applyRetention();
    ready = true;
    notifyListeners();
    if (baseUrl.trim().isNotEmpty) {
      refreshCapabilities();
    }
  }

  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async {
    processing = true;
    notifyListeners();
    lastAnalysisWasLocal = false;
    try {
      if (baseUrl.trim().isNotEmpty) {
        try {
          return await _api.analyze(text: text, source: source);
        } catch (_) {
          // A configured remote provider must not be represented as an AI result
          // produced locally. The capture UI keeps the original input and offers
          // an explicit retry instead.
          throw StateError('원격 AI 분석이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.');
        }
      }
      lastAnalysisWasLocal = true;
      return LocalAnalyzeService().analyze(text: text, source: source);
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<OpenLoop> analyzeImage({
    required String imagePath,
    String? companionText,
    String source = 'image',
  }) async {
    processing = true;
    notifyListeners();
    lastAnalysisWasLocal = false;
    try {
      if (baseUrl.trim().isNotEmpty) {
        try {
          return await _api.analyzeImage(
            imagePath: imagePath,
            companionText: companionText,
            source: source,
          );
        } catch (_) {
          throw StateError('이미지 AI 분석에 실패했습니다. 잠시 후 다시 시도해 주세요.');
        }
      }
      throw StateError('이미지 AI 분석 서버가 설정되지 않았습니다. 설정을 확인한 뒤 다시 시도해 주세요.');
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<void> saveLoop(OpenLoop loop) async {
    if (loop.isDraft) {
      throw StateError('분석 초안은 승인 전 저장할 수 없습니다.');
    }
    loops = _linkContextLocally(loop, loops);
    await repository.save(loops);
    notifyListeners();
    unawaited(_rescheduleLocalReminders());
  }

  /// Called after the first app frame so the system-owned permission sheet is
  /// presented once, then all future checkpoints are kept in sync locally.
  Future<bool> enableAutomaticReminders() async {
    final granted = await deviceActions.requestNotificationPermission();
    if (!granted) return false;
    return syncLocalReminders();
  }

  Future<void> triggerTestNotification({
    String title = 'BHC 뿌링클+콜라1.25L',
    String body = '오늘 마감되는 교환권입니다. 잊지 말고 지금 사용하세요!',
    String subtitle = '쿠폰 유효기간 알림',
  }) async {
    await deviceActions.requestNotificationPermission();
    await deviceActions.showNotification(
      title: title,
      body: body,
      subtitle: subtitle,
    );
  }

  Future<bool> syncLocalReminders() => deviceActions.syncReminders(loops);

  Future<void> _rescheduleLocalReminders() async {
    try {
      await syncLocalReminders();
    } catch (_) {
      // A loop remains useful even when the OS notification service is absent.
    }
  }

  Future<void> _cancelLocalReminders(OpenLoop loop) async {
    try {
      await deviceActions.cancelReminders(loop);
    } catch (_) {
      // Closing and deleting must not depend on a platform notification API.
    }
  }

  Future<OpenLoop> resolveAmbiguity(
    OpenLoop loop, {
    required String field,
    required Object value,
  }) async {
    final remaining = loop.missingFields
        .where((candidate) => candidate != field)
        .toList();
    var resolved = _applyAmbiguityLocally(
      loop,
      field: field,
      value: value,
      remaining: remaining,
    );
    if (loop.isDraft) {
      return resolved;
    }
    if (baseUrl.trim().isNotEmpty) {
      try {
        resolved = await _api.resolveAmbiguity(
          loopId: loop.id,
          field: field,
          value: value,
        );
      } catch (_) {
        lastAnalysisWasLocal = true;
      }
    }
    await saveLoop(resolved);
    return resolved;
  }

  OpenLoop editDraft(
    OpenLoop draft, {
    required String field,
    required Object value,
  }) {
    if (!draft.isDraft) {
      throw StateError('저장된 Loop는 초안 편집 경로를 사용할 수 없습니다.');
    }
    final remaining = draft.missingFields.toSet();
    final isEmpty = switch (value) {
      String text => text.trim().isEmpty,
      List<Object?> values => values.isEmpty,
      _ => false,
    };
    if (isEmpty) {
      remaining.add(field);
    } else {
      remaining.remove(field);
    }
    return _applyAmbiguityLocally(
      draft,
      field: field,
      value: value,
      remaining: remaining.toList(),
    );
  }

  Future<OpenLoop> approveDraft(OpenLoop draft) async {
    if (!draft.isDraft) {
      await saveLoop(draft);
      return draft;
    }
    final approved = _approvedDrafts[draft.id];
    if (approved != null) return approved;
    final existing = _approvalInFlight[draft.id];
    if (existing != null) return existing;

    final operation = _persistDraft(draft);
    _approvalInFlight[draft.id] = operation;
    try {
      final persisted = await operation;
      _approvedDrafts[draft.id] = persisted;
      await saveLoop(persisted);
      return persisted;
    } finally {
      _approvalInFlight.remove(draft.id);
    }
  }

  Future<OpenLoop> _persistDraft(OpenLoop draft) async {
    if (draft.persistence == LoopPersistence.remoteDraft &&
        baseUrl.trim().isNotEmpty) {
      try {
        return await _api.createLoop(
          draft: draft,
          retention: _retentionApiValue(retention),
        );
      } catch (_) {
        // 원격 서버 등록 실패 시에도 로컬에 즉시 영구 저장하여 데이터 손실 방지
      }
    }
    return _refreshLocalGraph(
      draft.copyWith(persistence: LoopPersistence.persisted),
    );
  }

  OpenLoop _applyAmbiguityLocally(
    OpenLoop loop, {
    required String field,
    required Object value,
    required List<String> remaining,
  }) {
    final state = remaining.isEmpty ? LoopState.open : LoopState.needsInput;
    final updated = switch (field) {
      'start_time' => loop.copyWith(
        state: state,
        time: value as String,
        missingFields: remaining,
      ),
      'date' => loop.copyWith(
        state: state,
        date: DateTime.parse(value as String),
        missingFields: remaining,
      ),
      'expires_on' => loop.copyWith(
        state: state,
        expiresOn: DateTime.parse(value as String),
        missingFields: remaining,
      ),
      'place' => loop.copyWith(
        state: state,
        place: value as String,
        missingFields: remaining,
      ),
      'title' => loop.copyWith(
        state: state,
        title: value as String,
        missingFields: remaining,
      ),
      'purpose' => loop.copyWith(
        state: state,
        purpose: value as String,
        missingFields: remaining,
      ),
      'participants' => loop.copyWith(
        state: state,
        participants: List<String>.from(value as List<String>),
        missingFields: remaining,
      ),
      _ => loop.copyWith(state: state, missingFields: remaining),
    };
    final bool isTemplateSummary = loop.summary == null ||
        (loop.summary!.contains('로 정리했습니다') ||
            loop.summary!.contains('확인이 필요합니다'));
    final summary = isTemplateSummary
        ? _summaryForLoop(updated)
        : loop.summary;
    return _refreshLocalGraph(
      updated.copyWith(summary: summary),
    );
  }

  Future<void> closeLoop(OpenLoop loop) async {
    final completedAt = DateTime.now();
    var closed = loop.copyWith(
      state: LoopState.closed,
      completedAt: completedAt,
      deleteAt: _retentionDeadline(retention, completedAt),
    );
    if (baseUrl.trim().isNotEmpty) {
      try {
        closed = await _api.complete(
          loopId: loop.id,
          retention: _retentionApiValue(retention),
        );
      } catch (_) {
        // The local copy still closes when the network is unavailable.
      }
    }
    if (retention == RetentionPolicy.immediately) {
      loops = loops.where((item) => item.id != loop.id).toList();
    } else {
      loops = loops.map((item) => item.id == loop.id ? closed : item).toList();
    }
    await _cancelLocalReminders(loop);
    await repository.save(loops);
    notifyListeners();
  }

  Future<void> updateChecklist(
    OpenLoop loop,
    LoopChecklistItem item,
    bool completed,
  ) async {
    var updated = loop.copyWith(
      checklist: loop.checklist
          .map(
            (entry) => entry.id == item.id
                ? entry.copyWith(completed: completed)
                : entry,
          )
          .toList(),
    );
    if (baseUrl.trim().isNotEmpty) {
      try {
        updated = await _api.updateChecklist(
          loopId: loop.id,
          itemId: item.id,
          completed: completed,
        );
      } catch (_) {
        // Checklist remains available offline and sync can be retried by the user.
      }
    }
    await saveLoop(updated);
    final requiredItems = updated.checklist.where((entry) => entry.isRequired);
    if (updated.checklist.isNotEmpty &&
        requiredItems.isNotEmpty &&
        requiredItems.every((entry) => entry.completed)) {
      await completeActionByType(updated, 'checklist');
    }
  }

  Future<void> updateAction(
    OpenLoop loop,
    LoopAction item,
    bool completed,
  ) async {
    var updated = loop.copyWith(
      actions: loop.actions
          .map(
            (entry) => entry.id == item.id
                ? entry.copyWith(completed: completed)
                : entry,
          )
          .toList(),
    );
    if (baseUrl.trim().isNotEmpty) {
      try {
        updated = await _api.updateAction(
          loopId: loop.id,
          itemId: item.id,
          completed: completed,
        );
      } catch (_) {
        // Action completion remains local-first so the user can keep moving.
      }
    }
    await saveLoop(updated);
  }

  Future<void> completeActionByType(OpenLoop loop, String type) async {
    for (final action in loop.actions) {
      if (action.type == type && !action.completed) {
        await updateAction(loop, action, true);
        return;
      }
    }
  }

  Future<void> updateCheckpoint(
    OpenLoop loop,
    LoopCheckpoint item,
    bool completed,
  ) async {
    var updated = loop.copyWith(
      checkpoints: loop.checkpoints
          .map(
            (entry) => entry.id == item.id
                ? entry.copyWith(completed: completed)
                : entry,
          )
          .toList(),
    );
    if (baseUrl.trim().isNotEmpty) {
      try {
        updated = await _api.updateCheckpoint(
          loopId: loop.id,
          itemId: item.id,
          completed: completed,
        );
      } catch (_) {
        // Checkpoints stay available offline and can be re-synced later.
      }
    }
    await saveLoop(updated);
  }

  Future<bool> deleteLoop(OpenLoop loop) async {
    if (baseUrl.trim().isNotEmpty) {
      try {
        await _api.deleteLoop(loopId: loop.id);
      } catch (_) {
        // Fall back to local deletion below.
      }
    }
    await _cancelLocalReminders(loop);
    loops = loops
        .where((item) => item.id != loop.id)
        .map(
          (item) => item.relatedLoopIds.contains(loop.id)
              ? item.copyWith(
                  relatedLoopIds: item.relatedLoopIds
                      .where((id) => id != loop.id)
                      .toList(),
                )
              : item,
        )
        .toList();
    await repository.save(loops);
    notifyListeners();
    return true;
  }

  Future<void> updateSettings({
    required String url,
    required RetentionPolicy policy,
  }) async {
    baseUrl = url.trim();
    retention = policy;
    await repository.saveBaseUrl(baseUrl);
    await repository.saveRetention(policy);
    _applyRetention();
    await repository.save(loops);
    notifyListeners();
  }

  Future<void> refreshCapabilities() async {
    if (baseUrl.trim().isEmpty) {
      capabilities = null;
      capabilitiesLoading = false;
      notifyListeners();
      return;
    }
    capabilitiesLoading = true;
    notifyListeners();
    try {
      capabilities = await ContextApi(baseUrl: baseUrl.trim()).capabilities();
    } catch (_) {
      capabilities = null;
    } finally {
      capabilitiesLoading = false;
      notifyListeners();
    }
  }

  void _applyRetention() {
    final now = DateTime.now();
    loops = loops.where((loop) {
      if (loop.state != LoopState.closed) return true;
      final deleteAt =
          loop.deleteAt ??
          _retentionDeadline(retention, loop.completedAt ?? loop.createdAt);
      return deleteAt == null || deleteAt.isAfter(now);
    }).toList();
  }
}

DateTime? _retentionDeadline(RetentionPolicy policy, DateTime completedAt) =>
    switch (policy) {
      RetentionPolicy.immediately => completedAt,
      RetentionPolicy.sevenDays => completedAt.add(const Duration(days: 7)),
      RetentionPolicy.thirtyDays => completedAt.add(const Duration(days: 30)),
      RetentionPolicy.keep => null,
    };

List<OpenLoop> _linkContextLocally(OpenLoop loop, List<OpenLoop> existing) {
  final placeKey = _contextPlaceKey(loop.place);
  final matchedIds = <String>{...loop.relatedLoopIds};
  if (placeKey != null) {
    for (final candidate in existing) {
      if (candidate.id != loop.id &&
          _contextPlaceKey(candidate.place) == placeKey) {
        matchedIds.add(candidate.id);
      }
    }
  }
  matchedIds.remove(loop.id);
  final linked = loop.copyWith(relatedLoopIds: matchedIds.toList()..sort());
  return [
    linked,
    for (final candidate in existing)
      if (candidate.id != loop.id)
        matchedIds.contains(candidate.id)
            ? candidate.copyWith(
                relatedLoopIds: <String>{
                  ...candidate.relatedLoopIds,
                  linked.id,
                }.toList()..sort(),
              )
            : candidate,
  ];
}

String? _contextPlaceKey(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final normalized = value.toLowerCase().replaceAll(
    RegExp(r'[^0-9a-z가-힣]+'),
    '',
  );
  return normalized.isEmpty ? null : normalized;
}

OpenLoop _refreshLocalGraph(OpenLoop loop) {
  final existingActions = {for (final item in loop.actions) item.type: item};
  final actions = <LoopAction>[];

  void ensureAction(String type, String title) {
    final existing = existingActions[type];
    actions.add(
      LoopAction(
        id: existing?.id ?? 'local-action-$type',
        type: type,
        title: title,
        completed: existing?.completed ?? false,
        metadata: existing?.metadata ?? const {},
      ),
    );
  }

  switch (loop.kind) {
    case LoopKind.appointment:
      ensureAction('calendar', '${loop.title} 일정 추가');
      if (loop.place != null) ensureAction('place', loop.place!);
      if (loop.checkpointAnchor != null) {
        ensureAction('reminder', '일정 알림 자동 예약');
      }
      break;
    case LoopKind.deadline:
      ensureAction('checklist', '마감 체크리스트');
      if (loop.checkpointAnchor != null) {
        ensureAction('reminder', '마감 알림 자동 예약');
      }
      break;
    case LoopKind.place:
      if (loop.place != null) ensureAction('place', '${loop.place!} 지도 열기');
      break;
    case LoopKind.coupon:
      ensureAction('coupon', '쿠폰 사용하기');
      if (loop.place != null) ensureAction('place', loop.place!);
      if (loop.checkpointAnchor != null) {
        ensureAction('reminder', '기한 알림 자동 예약');
      }
      break;
    case LoopKind.purchase:
      ensureAction('purchase', '${loop.title} 구매·배송 조회');
      if (loop.place != null) ensureAction('place', loop.place!);
      if (loop.checkpointAnchor != null) {
        ensureAction('reminder', '반품·보증 알림 자동 예약');
      }
      break;
    case LoopKind.reservation:
      ensureAction('reservation', '${loop.title} 예약 확인');
      ensureAction('calendar', '${loop.title} 캘린더 등록');
      if (loop.place != null) ensureAction('place', loop.place!);
      if (loop.checkpointAnchor != null) {
        ensureAction('reminder', '예약 당일 알림 자동 예약');
      }
      break;
  }
  var checklist = loop.checklist;
  if (loop.kind == LoopKind.deadline) {
    if (checklist.isEmpty) {
      checklist = const [
        LoopChecklistItem(id: 'local-checklist-1', title: '제출물 확인'),
        LoopChecklistItem(id: 'local-checklist-2', title: '최종 제출'),
      ];
    }
  } else {
    checklist = const [];
  }

  final existingByOffset = {
    for (final item in loop.checkpoints) item.offset: item,
  };
  final planned = planCheckpoints(
    kind: loop.kind,
    title: loop.title,
    eventAt: loop.checkpointAnchor,
  );
  final checkpoints = <LoopCheckpoint>[
    for (final plan in planned)
      if (existingByOffset[plan.offset] case final existing?)
        LoopCheckpoint(
          id: existing.id,
          offset: plan.offset,
          title: plan.title,
          dueAt: plan.dueAt,
          completed: existing.completed,
        )
      else
        LoopCheckpoint(
          id: 'local-checkpoint-${plan.offset.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
          offset: plan.offset,
          title: plan.title,
          dueAt: plan.dueAt,
        ),
  ];
  return loop.copyWith(
    actions: actions,
    checklist: checklist,
    checkpoints: checkpoints,
  );
}

String _summaryForLoop(OpenLoop loop) {
  final facts = <String>[
    loop.title,
    switch (loop.kind) {
      LoopKind.appointment => '일정',
      LoopKind.deadline => '마감',
      LoopKind.place => '장소 저장',
      LoopKind.coupon => '쿠폰',
      LoopKind.purchase => '구매',
      LoopKind.reservation => '예약',
    },
  ];
  if (loop.date != null) {
    facts.add(
      '${loop.date!.year.toString().padLeft(4, '0')}-${loop.date!.month.toString().padLeft(2, '0')}-${loop.date!.day.toString().padLeft(2, '0')}',
    );
  }
  if (loop.time != null) facts.add(loop.time!.substring(0, 5));
  if (loop.expiresOn != null) {
    facts.add(
      '기한 ${loop.expiresOn!.year.toString().padLeft(4, '0')}-${loop.expiresOn!.month.toString().padLeft(2, '0')}-${loop.expiresOn!.day.toString().padLeft(2, '0')}',
    );
  }
  if (loop.place != null) facts.add(loop.place!);
  if (loop.missingFields.isEmpty) return '${facts.join(' · ')}로 정리했습니다.';
  const labels = {
    'date': '날짜',
    'start_time': '시간',
    'expires_on': '쿠폰 기한',
    'place': '장소',
  };
  final unresolved = loop.missingFields
      .map((field) => labels[field] ?? field)
      .join(', ');
  return '${facts.join(' · ')}. $unresolved 확인이 필요합니다.';
}

String _retentionApiValue(RetentionPolicy value) => switch (value) {
  RetentionPolicy.immediately => 'immediately',
  RetentionPolicy.sevenDays => '7_days',
  RetentionPolicy.thirtyDays => '30_days',
  RetentionPolicy.keep => 'keep',
};
