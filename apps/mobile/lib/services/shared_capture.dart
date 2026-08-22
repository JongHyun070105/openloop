import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../models/open_loop.dart';

OpenLoop? parsePendingDraftJson(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(rawJson);
    return decoded is Map<String, dynamic>
        ? OpenLoop.fromAnalyzeJson(decoded)
        : null;
  } catch (_) {
    return null;
  }
}

/// A normalized native-share payload before it reaches the capture UI.
///
/// Keeping this transformation independent from a widget means the Android
/// intent and iOS Share Extension path can be regression-tested without a
/// device channel. Image paths are temporary files supplied by the plugin and
/// are never written to the app's loop repository.
class SharedCapturePayload {
  const SharedCapturePayload({required this.imagePath, required this.text});

  final String? imagePath;
  final String text;

  bool get isEmpty => imagePath == null && text.isEmpty;
}

String sanitizeSharedText(String text) {
  var cleaned = text.replaceAll(
    RegExp(r'[\u200B-\u200D\uFEFF\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]'),
    '',
  );
  if (cleaned.length > 8000) {
    cleaned = cleaned.substring(0, 8000);
  }
  return cleaned.trim();
}

SharedCapturePayload normalizeSharedMedia(List<SharedMediaFile> items) {
  String? imagePath;
  final textParts = <String>[];

  for (final item in items) {
    final value = item.path.trim();
    if (value.isEmpty) continue;
    if (item.type == SharedMediaType.image) {
      imagePath ??= value;
      continue;
    }
    if (item.type == SharedMediaType.text || item.type == SharedMediaType.url) {
      final sanitized = sanitizeSharedText(value);
      if (sanitized.isNotEmpty) {
        textParts.add(sanitized);
      }
    }
  }

  return SharedCapturePayload(
    imagePath: imagePath,
    text: sanitizeSharedText(textParts.join('\n')),
  );
}

SharedCapturePayload? parseSharedMediaJson(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List || decoded.isEmpty) return null;
    String? imagePath;
    final textParts = <String>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final path = item['path']?.toString() ?? '';
      final type = item['type']?.toString() ?? '';
      if (path.trim().isEmpty) continue;
      if (type == 'image' || type == 'SharedMediaType.image') {
        imagePath ??= path;
      } else {
        final sanitized = sanitizeSharedText(path);
        if (sanitized.isNotEmpty) {
          textParts.add(sanitized);
        }
      }
    }
    final payload = SharedCapturePayload(
      imagePath: imagePath,
      text: sanitizeSharedText(textParts.join('\n')),
    );
    return payload.isEmpty ? null : payload;
  } catch (_) {
    return null;
  }
}

class NativeSharedMediaBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.openloop.app/shared_group',
  );

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<SharedCapturePayload?> getAppGroupSharedCapture() async {
    if (!_isIOS) return null;
    try {
      final jsonStr = await _channel.invokeMethod<String>('getSharedMedia');
      return parseSharedMediaJson(jsonStr);
    } catch (_) {}
    return null;
  }

  static Future<void> clearAppGroupSharedCapture() async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod('clearSharedMedia');
    } catch (_) {}
  }

  static Future<OpenLoop?> getAppGroupPendingDraft({String? jobId}) async {
    if (!_isIOS) return null;
    try {
      final arguments = jobId == null ? null : <String, String>{'jobId': jobId};
      final jsonStr = await _channel.invokeMethod<String>(
        'getPendingDraft',
        arguments,
      );
      final draft = parsePendingDraftJson(jsonStr);
      if (draft != null) {
        await _channel.invokeMethod('clearPendingDraft', arguments);
        return draft;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> getPendingDraftRequest() async {
    if (!_isIOS) return null;
    try {
      final jobId = await _channel.invokeMethod<String>(
        'getPendingDraftRequest',
      );
      return jobId == null || jobId.trim().isEmpty ? null : jobId.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingDraftRequest(String jobId) async {
    if (!_isIOS || jobId.trim().isEmpty) return;
    try {
      await _channel.invokeMethod('clearPendingDraftRequest', {
        'jobId': jobId.trim(),
      });
    } catch (_) {}
  }

  static Future<void> configureShareExtension({
    required String apiBaseUrl,
    required String installationId,
  }) async {
    if (!_isIOS || apiBaseUrl.trim().isEmpty) return;
    await _channel.invokeMethod('configureShareExtension', {
      'apiBaseUrl': apiBaseUrl.trim(),
      'installationId': installationId,
    });
  }
}
