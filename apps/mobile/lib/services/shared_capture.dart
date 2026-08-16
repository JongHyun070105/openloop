import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// A normalized native-share payload before it reaches the capture UI.
///
/// Keeping this transformation independent from a widget means the Android
/// intent and iOS Share Extension path can be regression-tested without a
/// device channel. Image paths are temporary files supplied by the plugin and
/// are never written to the app's loop repository.
class SharedCapturePayload {
  const SharedCapturePayload({required this.imagePaths, required this.text});

  final List<String> imagePaths;
  final String text;

  bool get isEmpty => imagePaths.isEmpty && text.isEmpty;
  bool get hasMultipleImages => imagePaths.length > 1;
}

SharedCapturePayload normalizeSharedMedia(List<SharedMediaFile> items) {
  final seenImages = <String>{};
  final imagePaths = <String>[];
  final textParts = <String>[];

  for (final item in items) {
    final value = item.path.trim();
    if (value.isEmpty) continue;
    if (item.type == SharedMediaType.image) {
      if (seenImages.add(value)) imagePaths.add(value);
      continue;
    }
    if (item.type == SharedMediaType.text || item.type == SharedMediaType.url) {
      textParts.add(value);
    }
  }

  return SharedCapturePayload(
    imagePaths: List.unmodifiable(imagePaths),
    text: textParts.join('\n'),
  );
}
