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
  test('API client parses the snake_case analyze contract', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.example/v1/loops/analyze');
      expect(request.headers['x-openloop-install-id'], 'test-install');
      expect(jsonDecode(request.body), {'text': '7시 성수 예약', 'source': 'text'});
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'id': 'loop-42',
            'status': 'open',
            'suggested_question': null,
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

  test(
    'API client sends every selected image in one multipart request',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openloop-share-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.png');
      final second = File('${directory.path}/second.png');
      await first.writeAsBytes([1, 2, 3]);
      await second.writeAsBytes([4, 5, 6]);

      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api.example/v1/loops/analyze/image',
        );
        expect(request.headers['x-openloop-install-id'], 'test-install');
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        expect(RegExp('name="file"').allMatches(request.body).length, 2);
        expect(request.body, contains('name="source"'));
        expect(request.body, contains('screenshot'));
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
          ).analyzeImages(
            imagePaths: [first.path, second.path],
            companionText: '두 장을 함께 봐 주세요',
            source: 'screenshot',
          );

      expect(result.id, 'shared-loop');
      expect(result.source, 'screenshot');
    },
  );

  test('local analyzer asks only for a missing time', () async {
    final result = await LocalAnalyzeService().analyze(
      text: '내일 성수에서 만나자',
      source: 'text',
    );
    expect(result.state, LoopState.needsInput);
    expect(result.missingFields, ['start_time']);
    expect(result.place, '성수');
  });

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
      final result = await LocalAnalyzeService().analyze(
        text: 'AI 공모전 제출 마감 2026-08-22 23:00. 제출물: 작품 파일, 포트폴리오',
        source: 'text',
      );

      expect(result.actions, isNotEmpty);
      expect(
        result.actions.any((action) => action.type == 'checklist'),
        isTrue,
      );
      expect(result.checklist.map((item) => item.title), ['작품 파일', '포트폴리오']);
      expect(result.checkpoints, hasLength(3));
      expect(result.checkpoints.map((item) => item.offset), [
        'D-7',
        'D-3',
        'D-1',
      ]);
      expect(result.summary, contains('공모전 마감'));
    },
  );

  test(
    'local appointment creates event-driven before and after checkpoints',
    () async {
      final result = await LocalAnalyzeService().analyze(
        text: '2026-08-22 19:00 성수에서 회의',
        source: 'text',
      );

      expect(result.state, LoopState.open);
      expect(result.checkpoints.map((item) => item.offset), [
        'T-24h',
        'T-2h',
        'T+1d',
      ]);
    },
  );
}
