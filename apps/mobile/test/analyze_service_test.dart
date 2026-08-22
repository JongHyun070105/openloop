import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openloop_mobile/models/open_loop.dart';
import 'package:openloop_mobile/services/analyze_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(
    () => SharedPreferences.setMockInitialValues({
      'anonymous_installation_id': 'test-install',
    }),
  );
  test('text and image analysis share one server-aligned timeout', () {
    expect(ApiAnalyzeService.analysisTimeout, const Duration(seconds: 25));
  });
  test('API client parses the snake_case analyze contract', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.example/v1/analyze');
      expect(request.headers['x-openloop-install-id'], 'test-install');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['text'], '7시 성수 예약');
      expect(body['source'], 'text');
      expect(DateTime.tryParse(body['reference_at'] as String), isNotNull);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'id': 'loop-42',
            'status': 'open',
            'suggested_question': '참석자는 누구인가요?',
            'event': {
              'type': 'appointment',
              'title': '성수 약속',
              'date': '2026-08-22',
              'start_time': '19:00:00',
              'place': {'name': '성수'},
              'summary': '성수 저녁 약속을 8월 22일 19:00 성수에서 진행합니다.',
              'source': 'text',
              'confidence': {
                'date': .9,
                'time': .95,
                'location': .8,
                'title': .88,
              },
              'missing_fields': [],
              'reminders': [
                {'type': 'default', 'offset': '-1h'},
              ],
              'checklist': [
                {'id': 'portfolio', 'title': '포트폴리오', 'required': false},
                {'id': 'form', 'title': '지원서'},
              ],
              'resolution_note': '최종 합의를 선택했습니다.',
              'future_field': 'is ignored',
            },
            'actions': [
              {
                'id': 'action-calendar',
                'type': 'calendar',
                'title': '캘린더에 추가',
                'metadata': {'duration_minutes': 60},
              },
            ],
            'checkpoints': [
              {
                'id': 'checkpoint-t24h',
                'offset': 'T-24h',
                'title': '하루 전 확인',
                'due_at': '2026-08-21T19:00:00Z',
              },
            ],
            'delete_at': '2026-08-29T00:00:00Z',
          }),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final result = await ApiAnalyzeService(
      baseUrl: 'https://api.example/',
      client: client,
    ).analyze(text: '7시 성수 예약', source: 'text');
    expect(result.title, '성수 약속');
    expect(result.state, LoopState.open);
    expect(result.time, '19:00:00');
    expect(result.summary, '성수 저녁 약속을 8월 22일 19:00 성수에서 진행합니다.');
    expect(result.missingFields, isEmpty);
    expect(result.reminderOffsets, ['-1h']);
    expect(result.checklist.first.isRequired, isFalse);
    expect(result.checklist.last.isRequired, isTrue);
    expect(result.actions.single.metadata['duration_minutes'], 60);
    expect(result.checkpoints.single.dueAt, isNotNull);
    expect(result.deleteAt, isNotNull);
    expect(result.suggestedQuestion, '참석자는 누구인가요?');
    expect(result.persistence, LoopPersistence.remoteDraft);
  });

  test(
    'API client syncs checkpoint completion with installation ownership',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(
          request.url.toString(),
          'https://api.example/v1/loops/loop-42/checkpoints/checkpoint-t24h',
        );
        expect(request.headers['x-openloop-install-id'], 'test-install');
        expect(jsonDecode(request.body), {'completed': true});
        return http.Response(
          jsonEncode({
            'id': 'loop-42',
            'status': 'open',
            'event': {
              'type': 'deadline',
              'title': '제출 마감',
              'source': 'text',
              'confidence': {},
              'missing_fields': [],
              'reminders': [],
            },
            'checkpoints': [
              {
                'id': 'checkpoint-t24h',
                'offset': 'T-24h',
                'title': '하루 전 확인',
                'completed': true,
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final result =
          await ApiAnalyzeService(
            baseUrl: 'https://api.example',
            client: client,
          ).updateCheckpoint(
            loopId: 'loop-42',
            itemId: 'checkpoint-t24h',
            completed: true,
          );

      expect(result.checkpoints.single.completed, isTrue);
    },
  );

  test('API client sends one image with its supported MIME type', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openloop-share-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.png');
    await first.writeAsBytes([1, 2, 3]);

    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.example/v1/analyze/image');
      expect(request.headers['x-openloop-install-id'], 'test-install');
      expect(
        request.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(RegExp('name="file"').allMatches(request.body).length, 1);
      expect(request.body, contains('content-type: image/png'));
      expect(request.body, contains('name="source"'));
      expect(request.body, contains('screenshot'));
      expect(request.body, contains('name="reference_at"'));
      return http.Response(
        jsonEncode({
          'id': 'shared-loop',
          'status': 'open',
          'event': {
            'type': 'appointment',
            'title': '공유 일정',
            'source': 'screenshot',
            'confidence': {},
            'missing_fields': [],
            'reminders': [],
          },
        }),
        201,
        headers: const {'content-type': 'application/json'},
      );
    });

    final result =
        await ApiAnalyzeService(
          baseUrl: 'https://api.example',
          client: client,
        ).analyzeImage(
          imagePath: first.path,
          companionText: '이 이미지를 분석해 주세요',
          source: 'screenshot',
        );

    expect(result.id, 'shared-loop');
    expect(result.source, 'screenshot');
    expect(result.isDraft, isTrue);
  });

  test(
    'API client uploads browser-selected image bytes with its filename',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://api.example/v1/analyze/image');
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        final body = latin1.decode(request.bodyBytes);
        expect(body, contains('filename="capture.jpeg"'));
        expect(body.toLowerCase(), contains('content-type: image/jpeg'));
        expect(body, contains('name="source"'));
        return http.Response(
          jsonEncode({
            'id': 'browser-image-loop',
            'status': 'open',
            'event': {
              'type': 'appointment',
              'title': '브라우저 이미지 일정',
              'source': 'image',
              'confidence': {},
              'missing_fields': [],
              'reminders': [],
            },
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      });

      final result =
          await ApiAnalyzeService(
            baseUrl: 'https://api.example',
            client: client,
          ).analyzeImage(
            imagePath: 'blob:https://openloop-action.netlify.app/picked-image',
            imageBytes: const [0xff, 0xd8, 0xff, 0xdb],
            imageName: 'capture.jpeg',
          );

      expect(result.id, 'browser-image-loop');
    },
  );

  test(
    'API client persists a reviewed draft only through POST /v1/loops',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://api.example/v1/loops');
        expect(request.headers['x-openloop-install-id'], 'test-install');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect((body['event'] as Map<String, dynamic>)['title'], '향수 거래');
        expect(body['retention'], '7_days');
        return http.Response(
          jsonEncode({
            'id': 'persisted-42',
            'status': 'open',
            'created_at': '2026-08-16T11:00:00+09:00',
            'event': {
              'type': 'appointment',
              'title': '향수 거래',
              'date': '2026-08-16',
              'start_time': '16:00:00',
              'place': {'name': '종로5가역 12번 출구'},
              'source': 'image',
              'confidence': {
                'date': .98,
                'time': .98,
                'location': .98,
                'title': .9,
              },
              'missing_fields': [],
              'reminders': [],
            },
            'actions': [
              {'id': 'calendar-42', 'type': 'calendar', 'title': '일정 추가'},
            ],
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      });
      final draft = OpenLoop(
        id: 'draft-42',
        kind: LoopKind.appointment,
        state: LoopState.open,
        title: '향수 거래',
        source: 'image',
        createdAt: DateTime(2026, 8, 16),
        date: DateTime(2026, 8, 16),
        time: '16:00:00',
        place: '종로5가역 12번 출구',
        confidence: const {
          'date': .98,
          'time': .98,
          'location': .98,
          'title': .9,
        },
        persistence: LoopPersistence.remoteDraft,
      );

      final result = await ApiAnalyzeService(
        baseUrl: 'https://api.example',
        client: client,
      ).createLoop(draft: draft, retention: '7_days');

      expect(result.id, 'persisted-42');
      expect(result.persistence, LoopPersistence.persisted);
      expect(result.actions.single.id, 'calendar-42');
    },
  );

  test('image MIME mapping matches every server-supported extension', () {
    expect(imageMediaType('capture.JPG').toString(), 'image/jpeg');
    expect(imageMediaType('capture.jpeg').toString(), 'image/jpeg');
    expect(imageMediaType('capture.png').toString(), 'image/png');
    expect(imageMediaType('capture.webp').toString(), 'image/webp');
    expect(imageMediaType('capture.heic').toString(), 'image/heic');
    expect(imageMediaType('capture.heif').toString(), 'image/heif');
    expect(() => imageMediaType('capture.gif'), throwsArgumentError);
  });

  test('local analyzer asks only for a missing time', () async {
    final result = await LocalAnalyzeService().analyze(
      text: '내일 성수에서 만나자',
      source: 'text',
    );
    expect(result.state, LoopState.needsInput);
    expect(result.missingFields, ['start_time']);
    expect(result.place, '성수');
  });

  test(
    'local analyzer treats explicit dated transaction as appointment',
    () async {
      final result = await LocalAnalyzeService(
        clock: () => DateTime(2026, 8, 16, 11),
      ).analyze(text: '오늘 오후 4시 종로5가역 12번 출구에서 향수 거래', source: 'text');

      expect(result.kind, LoopKind.appointment);
      expect(result.date, DateTime(2026, 8, 16));
      expect(result.time, '16:00:00');
      expect(result.missingFields, isEmpty);
    },
  );

  test('local analyzer never fabricates missing event values', () async {
    final result = await LocalAnalyzeService().analyze(
      text: '프로젝트 회의',
      source: 'text',
    );
    expect(result.state, LoopState.needsInput);
    expect(result.date, isNull);
    expect(result.time, isNull);
    expect(result.place, isNull);
    expect(result.missingFields, ['date', 'start_time', 'place']);
  });

  test(
    'local deadline mirrors the deadline checklist and review cadence',
    () async {
      final result =
          await LocalAnalyzeService(
            clock: () => DateTime(2026, 8, 1, 9),
          ).analyze(
            text: 'AI 공모전 제출 마감 2026-08-22 23:00. 제출물: 작품 파일, 포트폴리오',
            source: 'text',
          );

      expect(result.actions, isNotEmpty);
      expect(
        result.actions.any((action) => action.type == 'checklist'),
        isTrue,
      );
      expect(result.checklist.map((item) => item.title), ['작품 파일', '포트폴리오']);
      expect(result.checkpoints, hasLength(1));
      expect(result.checkpoints.map((item) => item.offset), ['D-1']);
      expect(result.summary, contains('공모전 마감'));
    },
  );

  test('local appointment creates one useful pre-event checkpoint', () async {
    final result = await LocalAnalyzeService(
      clock: () => DateTime(2026, 8, 1, 9),
    ).analyze(text: '2026-08-22 19:00 성수에서 회의', source: 'text');

    expect(result.state, LoopState.open);
    expect(result.checkpoints.map((item) => item.offset), ['T-1h']);
  });

  test('local saved place never asks for date or time', () async {
    final result = await LocalAnalyzeService().analyze(
      text: '성수 난포 맛집 저장해줘',
      source: 'text',
    );

    expect(result.kind, LoopKind.place);
    expect(result.state, LoopState.open);
    expect(result.missingFields, isEmpty);
    expect(result.date, isNull);
    expect(result.time, isNull);
    expect(result.checkpoints, isEmpty);
    expect(result.actions.map((item) => item.type), ['place']);
  });

  test('local coupon keeps an expiry date without asking for a time', () async {
    final result = await LocalAnalyzeService(
      clock: () => DateTime(2026, 8, 1, 9),
    ).analyze(text: '스타벅스 쿠폰 2026-08-22까지 저장', source: 'text');

    expect(result.kind, LoopKind.coupon);
    expect(result.state, LoopState.open);
    expect(result.date, isNull);
    expect(result.expiresOn, DateTime(2026, 8, 22));
    expect(result.time, isNull);
    expect(result.missingFields, isEmpty);
    expect(result.checkpoints.map((item) => item.offset), ['D-1']);
  });

  test(
    'local purchase keeps an expiry date without asking for a time',
    () async {
      final result = await LocalAnalyzeService(
        clock: () => DateTime(2026, 8, 1, 9),
      ).analyze(text: '쿠팡 무선 이어폰 주문 2026-08-25까지 반품 가능', source: 'text');

      expect(result.kind, LoopKind.purchase);
      expect(result.state, LoopState.open);
      expect(result.expiresOn, DateTime(2026, 8, 25));
      expect(result.time, isNull);
      expect(result.missingFields, isEmpty);
      expect(result.checkpoints.map((item) => item.offset), ['D-1']);
      expect(result.actions.map((item) => item.type), contains('purchase'));
    },
  );

  test(
    'local reservation extracts date, time, place and creates T-2h checkpoint',
    () async {
      final result = await LocalAnalyzeService(
        clock: () => DateTime(2026, 8, 1, 9),
      ).analyze(text: '2026-08-20 14:30 김포공항 제주 항공권 예약', source: 'text');

      expect(result.kind, LoopKind.reservation);
      expect(result.state, LoopState.open);
      expect(result.date, DateTime(2026, 8, 20));
      expect(result.time, '14:30:00');
      expect(result.missingFields, isEmpty);
      expect(result.checkpoints.map((item) => item.offset), ['T-2h']);
      expect(result.actions.map((item) => item.type), contains('reservation'));
    },
  );
}
