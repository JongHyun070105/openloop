import 'package:flutter/foundation.dart';

import 'config.dart';
import 'models/open_loop.dart';
import 'services/analyze_service.dart';
import 'services/device_actions.dart';
import 'services/external_integrations.dart';
import 'services/loop_repository.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.repository,
    required this.deviceActions,
    String defaultBaseUrl = configuredOpenLoopApiBaseUrl,
  }) : _defaultBaseUrl = defaultBaseUrl;

  final LoopRepository repository;
  final DeviceActions deviceActions;
  final String _defaultBaseUrl;

  List<OpenLoop> loops = [];
  String baseUrl = '';
  RetentionPolicy retention = RetentionPolicy.sevenDays;
  bool ready = false;
  bool processing = false;
  bool lastAnalysisWasLocal = false;
  RemoteCapabilities? capabilities;
  bool capabilitiesLoading = false;

  Future<void> initialize() async {
    loops = await repository.load();
    baseUrl = (await repository.loadBaseUrl()) ?? _defaultBaseUrl;
    retention = await repository.loadRetention();
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
    final fallback = FallbackAnalyzeService(
      remote: baseUrl.trim().isEmpty
          ? null
          : ApiAnalyzeService(baseUrl: baseUrl.trim()),
      local: LocalAnalyzeService(),
    );
    try {
      final loop = await fallback.analyze(text: text, source: source);
      lastAnalysisWasLocal = fallback.usedFallback;
      return loop;
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<OpenLoop> analyzeImage({
    required String imagePath,
    String? companionText,
  }) async {
    processing = true;
    notifyListeners();
    lastAnalysisWasLocal = false;
    try {
      if (baseUrl.trim().isNotEmpty) {
        try {
          return await ApiAnalyzeService(
            baseUrl: baseUrl.trim(),
          ).analyzeImage(imagePath: imagePath, companionText: companionText);
        } catch (_) {
          lastAnalysisWasLocal = true;
        }
      } else {
        lastAnalysisWasLocal = true;
      }
      return LocalAnalyzeService().analyze(
        text: companionText?.trim().isNotEmpty == true
            ? companionText!.trim()
            : '선택한 이미지에서 일정을 분석해 주세요.',
        source: 'image',
      );
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<void> saveLoop(OpenLoop loop) async {
    loops = [loop, ...loops.where((item) => item.id != loop.id)];
    await repository.save(loops);
    notifyListeners();
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
    if (baseUrl.trim().isNotEmpty) {
      try {
        resolved = await ApiAnalyzeService(
          baseUrl: baseUrl.trim(),
        ).resolveAmbiguity(loopId: loop.id, field: field, value: value);
      } catch (_) {
        lastAnalysisWasLocal = true;
      }
    }
    await saveLoop(resolved);
    return resolved;
  }

  OpenLoop _applyAmbiguityLocally(
    OpenLoop loop, {
    required String field,
    required Object value,
    required List<String> remaining,
  }) {
    final state = remaining.isEmpty ? LoopState.open : LoopState.needsInput;
    return switch (field) {
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
  }

  Future<void> closeLoop(OpenLoop loop) async {
    var closed = loop.copyWith(state: LoopState.closed);
    if (baseUrl.trim().isNotEmpty) {
      try {
        closed = await ApiAnalyzeService(
          baseUrl: baseUrl.trim(),
        ).complete(loopId: loop.id, retention: _retentionApiValue(retention));
      } catch (_) {
        // The local copy still closes when the network is unavailable.
      }
    }
    if (retention == RetentionPolicy.immediately) {
      loops = loops.where((item) => item.id != loop.id).toList();
    } else {
      loops = loops.map((item) => item.id == loop.id ? closed : item).toList();
    }
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
        updated = await ApiAnalyzeService(baseUrl: baseUrl.trim())
            .updateChecklist(
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
        updated = await ApiAnalyzeService(
          baseUrl: baseUrl.trim(),
        ).updateAction(loopId: loop.id, itemId: item.id, completed: completed);
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
        updated = await ApiAnalyzeService(baseUrl: baseUrl.trim())
            .updateCheckpoint(
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
        await ApiAnalyzeService(
          baseUrl: baseUrl.trim(),
        ).deleteLoop(loopId: loop.id);
      } catch (_) {
        // Fall back to local deletion below.
      }
    }
    loops = loops.where((item) => item.id != loop.id).toList();
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
    final age = switch (retention) {
      RetentionPolicy.immediately => Duration.zero,
      RetentionPolicy.sevenDays => const Duration(days: 7),
      RetentionPolicy.thirtyDays => const Duration(days: 30),
      RetentionPolicy.keep => null,
    };
    if (age == null) return;
    loops = loops.where((loop) {
      if (loop.state != LoopState.closed) return true;
      return age != Duration.zero && now.difference(loop.createdAt) <= age;
    }).toList();
  }
}

String _retentionApiValue(RetentionPolicy value) => switch (value) {
  RetentionPolicy.immediately => 'immediately',
  RetentionPolicy.sevenDays => '7_days',
  RetentionPolicy.thirtyDays => '30_days',
  RetentionPolicy.keep => 'keep',
};
