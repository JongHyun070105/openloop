import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

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
      textParts.add(value);
    }
  }

  return SharedCapturePayload(imagePath: imagePath, text: textParts.join('\n'));
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
        textParts.add(path);
      }
    }
    final payload = SharedCapturePayload(
      imagePath: imagePath,
      text: textParts.join('\n'),
    );
    return payload.isEmpty ? null : payload;
  } catch (_) {
    return null;
  }
}

class NativeSharedMediaBridge {
  static const MethodChannel _channel =
      MethodChannel('com.openloop.app/shared_group');

  static Future<SharedCapturePayload?> getAppGroupSharedCapture() async {
    if (!Platform.isIOS) return null;
    try {
      final jsonStr = await _channel.invokeMethod<String>('getSharedMedia');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        await _channel.invokeMethod('clearSharedMedia');
        return parseSharedMediaJson(jsonStr);
      }
    } catch (_) {}
    return null;
  }
}
