import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openloop_mobile/models/open_loop.dart';
import 'package:openloop_mobile/services/shared_capture.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test(
    'parseSharedMediaJson parses JSON array saved in App Group UserDefaults',
    () {
      const rawJson =
          '[{"path":"/var/mobile/Containers/Shared/AppGroup/UUID.png","type":"image","mimeType":"image/png"}]';
      final payload = parseSharedMediaJson(rawJson);
      expect(payload, isNotNull);
      expect(
        payload!.imagePath,
        equals('/var/mobile/Containers/Shared/AppGroup/UUID.png'),
      );
      expect(payload.text, isEmpty);
    },
  );

  test('parsePendingDraftJson parses the backend analysis contract', () {
    const draftJson = '''
    {
      "status": "open",
      "event": {
        "id": "draft_123456",
        "type": "coupon",
        "title": "BHC 뿌링클+콜라1.25L 교환",
        "expires_on": "2024-08-08",
        "summary": "BHC 뿌링클+콜라1.25L 교환 쿠폰 유효기간은 2024-08-08까지입니다.",
        "source": "image",
        "missing_fields": []
      },
      "actions": [
        {"id": "action_1", "type": "calendar", "label": "만료일 캘린더 등록", "completed": false}
      ],
      "checklist": [],
      "checkpoints": []
    }
    ''';

    final draft = parsePendingDraftJson(draftJson)!;
    expect(draft.id, equals('draft_123456'));
    expect(draft.title, equals('BHC 뿌링클+콜라1.25L 교환'));
    expect(draft.kind, equals(LoopKind.coupon));
    expect(draft.expiresOn, equals(DateTime(2024, 8, 8)));
    expect(draft.isDraft, isTrue);
  });

  test('parsePendingDraftJson rejects malformed data', () {
    expect(parsePendingDraftJson('{not-json'), isNull);
    expect(parsePendingDraftJson('[]'), isNull);
  });

  test('pending draft is acknowledged only after successful parsing', () async {
    const channel = MethodChannel('com.openloop.app/shared_group');
    final calls = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getPendingDraft') return '{not-json';
          return true;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    expect(await NativeSharedMediaBridge.getAppGroupPendingDraft(), isNull);
    expect(calls, ['getPendingDraft']);
  });

  test(
    'job-scoped pending draft reads and clears the same share job',
    () async {
      const channel = MethodChannel('com.openloop.app/shared_group');
      const jobId = '9ca2c18d-2937-45b6-a84c-734b9c79894e';
      final calls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getPendingDraftRequest') return jobId;
            if (call.method == 'getPendingDraft') {
              return '''
              {"status":"open","event":{"id":"draft_job","type":"appointment","title":"저녁 약속","source":"image","missing_fields":[]},"actions":[],"checklist":[],"checkpoints":[]}
            ''';
            }
            return true;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect(await NativeSharedMediaBridge.getPendingDraftRequest(), jobId);
      final draft = await NativeSharedMediaBridge.getAppGroupPendingDraft(
        jobId: jobId,
      );
      await NativeSharedMediaBridge.clearPendingDraftRequest(jobId);

      expect(draft?.id, 'draft_job');
      expect(calls[1].arguments, {'jobId': jobId});
      expect(calls[2].arguments, {'jobId': jobId});
      expect(calls[3].arguments, {'jobId': jobId});
    },
  );
}
