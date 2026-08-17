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
