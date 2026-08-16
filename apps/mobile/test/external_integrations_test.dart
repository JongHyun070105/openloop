import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openloop_mobile/services/external_integrations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(
    () => SharedPreferences.setMockInitialValues({
      'anonymous_installation_id': 'test-install',
    }),
  );
  test('parses place and KMA weather boundary responses', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/places/search')) {
        expect(request.headers['x-openloop-install-id'], 'test-install');
        expect(request.url.queryParameters['q'], '난포 성수');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {
                'name': '난포 성수',
                'address': '서울 성동구',
                'latitude': 37.54,
                'longitude': 127.05,
                'kakao_map_url': 'https://place.map.kakao.com/1',
              },
            ]),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(request.url.path, '/v1/weather');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'available': true,
            'summary': '맑음',
            'temperature_c': 24.5,
            'precipitation_probability': 10,
            'provider': 'kma',
          }),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = ContextApi(baseUrl: 'https://api.example', client: client);
    final places = await api.searchPlaces('난포 성수');
    final weather = await api.weather(
      latitude: places.single.latitude,
      longitude: places.single.longitude,
    );
    expect(places.single.address, '서울 성동구');
    expect(weather.available, isTrue);
    expect(weather.summary, '맑음');
    expect(weather.precipitationProbability, 10);
  });

  test('returns graceful no-op values without an API URL', () async {
    final api = ContextApi(baseUrl: '');
    expect(await api.searchPlaces('성수'), isEmpty);
    expect(
      (await api.weather(latitude: 37.5, longitude: 127)).available,
      isFalse,
    );
  });

  test(
    'reads provider capability flags without exposing credentials',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/capabilities');
        expect(request.headers['x-openloop-install-id'], 'test-install');
        return http.Response(
          jsonEncode({
            'analysis_enabled': true,
            'analysis_model': 'gemini-3.5-flash-lite',
            'places_enabled': true,
            'weather_enabled': false,
            'push_enabled': false,
            'analytics_enabled': true,
            'sentry_enabled': true,
          }),
          200,
        );
      });

      final capabilities = await ContextApi(
        baseUrl: 'https://api.example',
        client: client,
      ).capabilities();

      expect(capabilities?.analysisEnabled, isTrue);
      expect(capabilities?.analysisModel, 'gemini-3.5-flash-lite');
      expect(capabilities?.placesEnabled, isTrue);
      expect(capabilities?.weatherEnabled, isFalse);
    },
  );

  test('registers FCM token with anonymous installation ownership', () async {
    final client = MockClient((request) async {
      expect(request.headers['x-openloop-install-id'], 'test-install');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.containsKey('installation_id'), isFalse);
      expect(body['token'], 'fcm-token');
      return http.Response(
        jsonEncode({'registered': true, 'provider': 'fcm'}),
        200,
      );
    });
    expect(
      await ContextApi(
        baseUrl: 'https://api.example',
        client: client,
      ).registerPushToken('fcm-token'),
      isTrue,
    );
  });
}
