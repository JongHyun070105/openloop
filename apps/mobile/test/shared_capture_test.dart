import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/services/shared_capture.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  test('normalizes text, URLs, and every unique shared image', () {
    final payload = normalizeSharedMedia([
      SharedMediaFile(
        path: '/tmp/screenshot-1.png',
        type: SharedMediaType.image,
        mimeType: 'image/png',
      ),
      SharedMediaFile(path: '내일 7시', type: SharedMediaType.text),
      SharedMediaFile(
        path: 'https://example.com/event',
        type: SharedMediaType.url,
      ),
      SharedMediaFile(
        path: '/tmp/screenshot-2.png',
        type: SharedMediaType.image,
        mimeType: 'image/png',
      ),
      SharedMediaFile(
        path: '/tmp/screenshot-1.png',
        type: SharedMediaType.image,
        mimeType: 'image/png',
      ),
    ]);

    expect(payload.imagePaths, [
      '/tmp/screenshot-1.png',
      '/tmp/screenshot-2.png',
    ]);
    expect(payload.text, '내일 7시\nhttps://example.com/event');
    expect(payload.hasMultipleImages, isTrue);
  });

  test('ignores empty and unsupported native share items', () {
    final payload = normalizeSharedMedia([
      SharedMediaFile(path: ' ', type: SharedMediaType.text),
      SharedMediaFile(path: '/tmp/document.pdf', type: SharedMediaType.file),
    ]);

    expect(payload.isEmpty, isTrue);
  });
}
