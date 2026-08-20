import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/services/shared_capture.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  test(
    'normalizes text and URLs while accepting only the first shared image',
    () {
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

      expect(payload.imagePath, '/tmp/screenshot-1.png');
      expect(payload.text, '내일 7시\nhttps://example.com/event');
    },
  );

  test('ignores empty and unsupported native share items', () {
    final payload = normalizeSharedMedia([
      SharedMediaFile(path: ' ', type: SharedMediaType.text),
      SharedMediaFile(path: '/tmp/document.pdf', type: SharedMediaType.file),
    ]);

    expect(payload.isEmpty, isTrue);
  });

  test('parseSharedMediaJson parses JSON array saved in App Group UserDefaults', () {
    const rawJson = '[{"path":"/var/mobile/Containers/Shared/AppGroup/UUID.png","type":"image","mimeType":"image/png"}]';
    final payload = parseSharedMediaJson(rawJson);
    expect(payload, isNotNull);
    expect(payload!.imagePath, equals('/var/mobile/Containers/Shared/AppGroup/UUID.png'));
    expect(payload.text, isEmpty);
  });
}
