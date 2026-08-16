import 'dart:convert';

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
            'status': 'open',
            'suggested_question': null,
            'event': {
              'type': 'appointment',
              'title': '성수 약속',
              'date': '2026-08-22',
              'start_time': '19:00:00',
              'place': {'name': '성수'},
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
    expect(result.missingFields, isEmpty);
    expect(result.reminderOffsets, ['-1h']);
    expect(result.checklist.first.isRequired, isFalse);
    expect(result.checklist.last.isRequired, isTrue);
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
}
