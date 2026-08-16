import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/open_loop.dart';
import 'installation_identity.dart';

abstract interface class AnalyzeService {
  Future<OpenLoop> analyze({required String text, required String source});
}

class ApiAnalyzeService implements AnalyzeService {
  ApiAnalyzeService({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  @override
  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async {
    final installationId = await InstallationIdentity.get();
    final response = await _client
        .post(
          Uri.parse('$_root/v1/loops/analyze'),
          headers: {
            'content-type': 'application/json',
            'X-OpenLoop-Install-Id': installationId,
          },
          body: jsonEncode({'text': text, 'source': source}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('분석 서버 오류 (${response.statusCode})');
    }
    return OpenLoop.fromAnalyzeJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  String get _root => baseUrl.replaceAll(RegExp(r'/$'), '');

  Future<OpenLoop> analyzeImage({
    required String imagePath,
    String? companionText,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_root/v1/loops/analyze/image'),
    );
    request.headers['X-OpenLoop-Install-Id'] = await InstallationIdentity.get();
    request.files.add(await http.MultipartFile.fromPath('file', imagePath));
    if (companionText?.trim().isNotEmpty == true) {
      request.fields['companion_text'] = companionText!.trim();
    }
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 25));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('이미지 분석 서버 오류 (${response.statusCode})');
    }
    return OpenLoop.fromAnalyzeJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<OpenLoop> resolveAmbiguity({
    required String loopId,
    required String field,
    required Object value,
  }) => _mutate(
    method: 'PATCH',
    path: '/v1/loops/$loopId/ambiguity',
    body: {'field': field, 'value': value},
  );

  Future<OpenLoop> complete({
    required String loopId,
    required String retention,
  }) => _mutate(
    method: 'POST',
    path: '/v1/loops/$loopId/complete',
    body: {'retention': retention},
  );

  Future<OpenLoop> updateChecklist({
    required String loopId,
    required String itemId,
    required bool completed,
  }) => _mutate(
    method: 'PATCH',
    path: '/v1/loops/$loopId/checklist/$itemId',
    body: {'completed': completed},
  );

  Future<OpenLoop> updateAction({
    required String loopId,
    required String itemId,
    required bool completed,
  }) => _mutate(
    method: 'PATCH',
    path: '/v1/loops/$loopId/actions/$itemId',
    body: {'completed': completed},
  );

  Future<OpenLoop> updateCheckpoint({
    required String loopId,
    required String itemId,
    required bool completed,
  }) => _mutate(
    method: 'PATCH',
    path: '/v1/loops/$loopId/checkpoints/$itemId',
    body: {'completed': completed},
  );

  Future<void> deleteLoop({required String loopId}) async {
    final request = http.Request('DELETE', Uri.parse('$_root/v1/loops/$loopId'))
      ..headers['X-OpenLoop-Install-Id'] = await InstallationIdentity.get();
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 204) {
      throw StateError('Loop 삭제 실패 (${response.statusCode})');
    }
  }

  Future<OpenLoop> _mutate({
    required String method,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final request = http.Request(method, Uri.parse('$_root$path'))
      ..headers['content-type'] = 'application/json'
      ..headers['X-OpenLoop-Install-Id'] = await InstallationIdentity.get()
      ..body = jsonEncode(body);
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Loop 동기화 오류 (${response.statusCode})');
    }
    return OpenLoop.fromAnalyzeJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}

class LocalAnalyzeService implements AnalyzeService {
  @override
  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final now = DateTime.now();
    final isDeadline =
        text.contains('마감') || text.contains('제출') || text.contains('공모전');
    final date = _explicitDate(text, now);
    final startTime = _explicitTime(text);
    final place = _explicitPlace(text);
    final missingFields = <String>[
      if (date == null) 'date',
      if (startTime == null) 'start_time',
      if (!isDeadline && place == null) 'place',
    ];
    final fallbackJson = <String, dynamic>{
      'status': missingFields.isEmpty ? 'open' : 'needs_input',
      'event': {
        'type': isDeadline ? 'deadline' : 'appointment',
        'title': _localTitle(text, isDeadline),
        'date': date == null
            ? null
            : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'start_time': startTime,
        'place': place == null ? null : {'name': place},
        'purpose': null,
        'source': source,
        'confidence': {
          'date': date == null ? 0.0 : .96,
          'time': startTime == null ? 0.0 : .97,
          'location': place == null ? 0.0 : .9,
          'title': .7,
        },
        'missing_fields': missingFields,
        'reminders': isDeadline && date != null
            ? [
                {'type': 'checkpoint', 'offset': '-1d'},
              ]
            : startTime != null
            ? [
                {'type': 'default', 'offset': '-1h'},
              ]
            : <Map<String, String>>[],
        'resolution_note': 'API 연결 전에는 텍스트에 명시된 값만 추출합니다. 저장 전에 빈 항목을 확인하세요.',
      },
      'suggested_question': _localQuestion(missingFields),
    };
    return OpenLoop.fromAnalyzeJson(fallbackJson);
  }
}

DateTime? _explicitDate(String text, DateTime now) {
  final fullMatch = RegExp(
    r'\b(20\d{2})[-./](\d{1,2})[-./](\d{1,2})\b',
  ).firstMatch(text);
  final monthDayMatch = RegExp(r'\b(\d{1,2})월\s*(\d{1,2})일').firstMatch(text);
  try {
    if (fullMatch != null) {
      return DateTime(
        int.parse(fullMatch.group(1)!),
        int.parse(fullMatch.group(2)!),
        int.parse(fullMatch.group(3)!),
      );
    }
    if (monthDayMatch != null) {
      return DateTime(
        now.year,
        int.parse(monthDayMatch.group(1)!),
        int.parse(monthDayMatch.group(2)!),
      );
    }
  } on FormatException {
    return null;
  }
  if (text.contains('모레')) return DateTime(now.year, now.month, now.day + 2);
  if (text.contains('내일')) return DateTime(now.year, now.month, now.day + 1);
  if (text.contains('오늘')) return DateTime(now.year, now.month, now.day);
  const weekdays = <String, int>{
    '월요일': DateTime.monday,
    '화요일': DateTime.tuesday,
    '수요일': DateTime.wednesday,
    '목요일': DateTime.thursday,
    '금요일': DateTime.friday,
    '토요일': DateTime.saturday,
    '일요일': DateTime.sunday,
  };
  for (final entry in weekdays.entries) {
    if (text.contains(entry.key)) {
      final days = (entry.value - now.weekday + 7) % 7;
      return DateTime(now.year, now.month, now.day + (days == 0 ? 7 : days));
    }
  }
  return null;
}

String? _explicitTime(String text) {
  final candidates = <MapEntry<int, String>>[];
  for (final match in RegExp(
    r'(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)',
  ).allMatches(text)) {
    candidates.add(
      MapEntry(
        match.start,
        '${match.group(1)!.padLeft(2, '0')}:${match.group(2)!}:00',
      ),
    );
  }
  for (final match in RegExp(
    r'(?:(오전|오후)\s*)?(1[0-2]|0?\d)\s*시(?:\s*([0-5]?\d)\s*분?)?',
  ).allMatches(text)) {
    var hour = int.parse(match.group(2)!);
    final minute = int.parse(match.group(3) ?? '0');
    if (match.group(1) == '오후' && hour < 12) hour += 12;
    if (match.group(1) == '오전' && hour == 12) hour = 0;
    candidates.add(
      MapEntry(
        match.start,
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00',
      ),
    );
  }
  if (candidates.isEmpty) return null;
  candidates.sort((left, right) => left.key.compareTo(right.key));
  return candidates.last.value;
}

String? _explicitPlace(String text) {
  for (final marker in ['에서', '으로']) {
    final markerIndex = text.indexOf(marker);
    if (markerIndex < 0) continue;
    final prefix = text.substring(0, markerIndex).trim();
    if (prefix.isEmpty) continue;
    final afterAt = prefix.lastIndexOf('에');
    final candidate =
        (afterAt >= 0
                ? prefix.substring(afterAt + 1)
                : prefix.split(RegExp(r'\s+')).last)
            .trim()
            .replaceAll(RegExp(r'^[, .!?…]+|[, .!?…]+$'), '');
    if (RegExp(
      r"^[가-힣A-Za-z0-9][가-힣A-Za-z0-9 .'-]{0,39}$",
    ).hasMatch(candidate)) {
      return candidate;
    }
  }
  return null;
}

String _localTitle(String text, bool isDeadline) {
  if (isDeadline) return text.contains('공모전') ? '공모전 마감' : '마감 일정';
  for (final word in ['회의', '미팅', '약속', '예약']) {
    if (text.contains(word)) return word;
  }
  return '새 일정';
}

String? _localQuestion(List<String> missingFields) {
  if (missingFields.isEmpty) return null;
  return switch (missingFields.first) {
    'date' => '언제로 등록할까요?',
    'start_time' => '몇 시로 등록할까요?',
    'place' => '어디에서 진행할까요?',
    _ => '일정 정보를 조금만 더 알려주세요.',
  };
}

class FallbackAnalyzeService implements AnalyzeService {
  FallbackAnalyzeService({required this.remote, required this.local});
  final AnalyzeService? remote;
  final AnalyzeService local;

  bool usedFallback = false;

  @override
  Future<OpenLoop> analyze({
    required String text,
    required String source,
  }) async {
    usedFallback = false;
    if (remote != null) {
      try {
        return await remote!.analyze(text: text, source: source);
      } catch (_) {
        usedFallback = true;
      }
    } else {
      usedFallback = true;
    }
    return local.analyze(text: text, source: source);
  }
}
