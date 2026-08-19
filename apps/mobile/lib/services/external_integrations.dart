import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'installation_identity.dart';

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.kakaoMapUrl,
  });
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String kakaoMapUrl;

  factory PlaceResult.fromJson(Map<String, dynamic> json) => PlaceResult(
    name: json['name'] as String? ?? '',
    address: json['address'] as String? ?? '',
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    kakaoMapUrl: json['kakao_map_url'] as String? ?? '',
  );
}

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.available,
    this.summary,
    this.temperatureC,
    this.precipitationProbability,
  });
  final bool available;
  final String? summary;
  final double? temperatureC;
  final int? precipitationProbability;

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) =>
      WeatherSnapshot(
        available: json['available'] as bool? ?? false,
        summary: json['summary'] as String?,
        temperatureC: (json['temperature_c'] as num?)?.toDouble(),
        precipitationProbability: (json['precipitation_probability'] as num?)
            ?.round(),
      );
}

class RemoteCapabilities {
  const RemoteCapabilities({
    required this.analysisEnabled,
    required this.analysisModel,
    required this.placesEnabled,
    required this.weatherEnabled,
    required this.pushEnabled,
    required this.analyticsEnabled,
    required this.sentryEnabled,
  });

  final bool analysisEnabled;
  final String? analysisModel;
  final bool placesEnabled;
  final bool weatherEnabled;
  final bool pushEnabled;
  final bool analyticsEnabled;
  final bool sentryEnabled;

  factory RemoteCapabilities.fromJson(Map<String, dynamic> json) =>
      RemoteCapabilities(
        analysisEnabled: json['analysis_enabled'] as bool? ?? false,
        analysisModel: json['analysis_model'] as String?,
        placesEnabled: json['places_enabled'] as bool? ?? false,
        weatherEnabled: json['weather_enabled'] as bool? ?? false,
        pushEnabled: json['push_enabled'] as bool? ?? false,
        analyticsEnabled: json['analytics_enabled'] as bool? ?? false,
        sentryEnabled: json['sentry_enabled'] as bool? ?? false,
      );
}

class ContextApi {
  ContextApi({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;
  String get _root => baseUrl.replaceAll(RegExp(r'/$'), '');

  Future<List<PlaceResult>> searchPlaces(String query) async {
    if (_root.isEmpty || query.trim().isEmpty) return [];
    final response = await _client
        .get(
          Uri.parse(
            '$_root/v1/places/search',
          ).replace(queryParameters: {'q': query.trim()}),
          headers: {'X-OpenLoop-Install-Id': await InstallationIdentity.get()},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return [];
    return (jsonDecode(response.body) as List<dynamic>)
        .map((item) => PlaceResult.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<WeatherSnapshot> weather({
    required double latitude,
    required double longitude,
    DateTime? at,
  }) async {
    if (_root.isEmpty) return const WeatherSnapshot(available: false);
    final params = <String, String>{
      'lat': latitude.toString(),
      'lon': longitude.toString(),
      if (at != null) 'at': at.toIso8601String(),
    };
    final response = await _client
        .get(
          Uri.parse('$_root/v1/weather').replace(queryParameters: params),
          headers: {'X-OpenLoop-Install-Id': await InstallationIdentity.get()},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return const WeatherSnapshot(available: false);
    }
    return WeatherSnapshot.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<RemoteCapabilities?> capabilities() async {
    if (_root.isEmpty) return null;
    final response = await _client
        .get(
          Uri.parse('$_root/v1/capabilities'),
          headers: {'X-OpenLoop-Install-Id': await InstallationIdentity.get()},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    return RemoteCapabilities.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<bool> registerPushToken(String token) async {
    if (_root.isEmpty) return false;
    final installationId = await InstallationIdentity.get();
    final response = await _client
        .post(
          Uri.parse('$_root/v1/devices/push-token'),
          headers: {
            'content-type': 'application/json',
            'X-OpenLoop-Install-Id': installationId,
          },
          body: jsonEncode({
            'token': token,
            'platform': Platform.isIOS ? 'ios' : 'android',
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    return (jsonDecode(response.body) as Map<String, dynamic>)['registered']
            as bool? ??
        false;
  }

  Future<bool> openKakaoRoute(PlaceResult place) async {
    final native = Uri.parse(
      'kakaomap://route?ep=${place.latitude},${place.longitude}&by=CAR',
    );
    if (await canLaunchUrl(native)) return launchUrl(native);
    final encodedName = Uri.encodeComponent(place.name);
    final webRoute = Uri.parse(
      'https://map.kakao.com/link/to/$encodedName,${place.latitude},${place.longitude}',
    );
    if (await launchUrl(webRoute, mode: LaunchMode.externalApplication)) {
      return true;
    }
    final web = Uri.tryParse(place.kakaoMapUrl);
    return web != null &&
        await launchUrl(web, mode: LaunchMode.externalApplication);
  }

  Future<bool> openKakaoMap(PlaceResult place) => openKakaoRoute(place);
}

class AppIntegrations {
  AppIntegrations._();
  static final instance = AppIntegrations._();

  final pendingLoopId = ValueNotifier<String?>(null);
  bool _posthogReady = false;
  bool _firebaseReady = false;
  bool _tokenRefreshSubscribed = false;
  bool _foregroundMessageSubscribed = false;
  String _apiBaseUrl = '';
  final _foregroundNotifications = _ForegroundNotificationPresenter();

  static const _allowedAnalyticsEvents = {
    'capture_started',
    'loop_closed',
    'place_opened',
  };

  Future<void> initialize({required String apiBaseUrl}) async {
    await _initializePosthog();
    await _initializeFirebase(apiBaseUrl);
  }

  Future<void> _initializePosthog() async {
    const token = String.fromEnvironment('POSTHOG_PROJECT_API_KEY');
    if (token.isEmpty) return;
    const host = String.fromEnvironment(
      'POSTHOG_HOST',
      defaultValue: 'https://us.i.posthog.com',
    );
    final config = PostHogConfig(token)
      ..host = host
      ..captureApplicationLifecycleEvents = false
      ..capturePushNotificationSubscriptions = false
      ..capturePushNotificationOpened = false
      ..personProfiles = PostHogPersonProfiles.never
      ..sessionReplay = false
      ..beforeSend = [
        (event) => _allowedAnalyticsEvents.contains(event.event) ? event : null,
      ];
    try {
      await Posthog().setup(config);
      _posthogReady = true;
    } catch (_) {}
  }

  Future<void> _initializeFirebase(String apiBaseUrl) async {
    _apiBaseUrl = apiBaseUrl;
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if ([apiKey, appId, senderId, projectId].any((value) => value.isEmpty)) {
      return;
    }
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: senderId,
          projectId: projectId,
        ),
      );
      _firebaseReady = true;
      FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
      if (!_foregroundMessageSubscribed) {
        _foregroundMessageSubscribed = true;
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      }
      _handleMessage(await FirebaseMessaging.instance.getInitialMessage());
    } catch (error, stackTrace) {
      await captureError(error, stackTrace);
    }
  }

  Future<bool> enablePushNotifications({String? apiBaseUrl}) async {
    if (apiBaseUrl != null) _apiBaseUrl = apiBaseUrl.trim();
    if (!_firebaseReady || _apiBaseUrl.isEmpty) return false;
    try {
      final permission = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        return false;
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return false;
      final registered = await ContextApi(
        baseUrl: _apiBaseUrl,
      ).registerPushToken(token);
      if (!_tokenRefreshSubscribed) {
        _tokenRefreshSubscribed = true;
        FirebaseMessaging.instance.onTokenRefresh.listen(
          (value) => ContextApi(baseUrl: _apiBaseUrl).registerPushToken(value),
        );
      }
      return registered;
    } catch (error, stackTrace) {
      await captureError(error, stackTrace);
      return false;
    }
  }

  void _handleMessage(RemoteMessage? message) {
    final loopId =
        message?.data['loop_id'] as String? ??
        (message?.data['loopKey'] as String?)?.replaceFirst('LOOP#', '');
    if (loopId?.isNotEmpty == true) pendingLoopId.value = loopId;
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    _handleMessage(message);
    try {
      await _foregroundNotifications.show(message);
    } catch (error, stackTrace) {
      await captureError(error, stackTrace);
    }
  }

  Future<void> capture(String eventName) async {
    if (!_posthogReady || !_allowedAnalyticsEvents.contains(eventName)) return;
    try {
      await Posthog().capture(eventName: eventName);
    } catch (_) {}
  }

  Future<void> captureError(Object error, StackTrace stackTrace) async {
    const dsn = String.fromEnvironment('SENTRY_DSN');
    if (dsn.isEmpty) return;
    await Sentry.captureException(error, stackTrace: stackTrace);
  }
}

class _ForegroundNotificationPresenter {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> show(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    if (!_initialized) {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      _initialized = true;
    }
    await _plugin.show(
      message.messageId?.hashCode ?? DateTime.now().microsecondsSinceEpoch,
      notification.title ?? 'OpenLoop 알림',
      notification.body ?? '확인할 일정이 있습니다.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'openloop_checkpoints',
          'OpenLoop checkpoint alerts',
          channelDescription: 'OpenLoop 서버 체크포인트 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }
}

Future<void> runWithObservability(Future<void> Function() appRunner) async {
  const dsn = String.fromEnvironment('SENTRY_DSN');
  if (dsn.isEmpty) return appRunner();
  await SentryFlutter.init((options) {
    options.dsn = dsn;
    options.sendDefaultPii = false;
    options.attachScreenshot = false;
    options.tracesSampleRate = 0;
    options.beforeBreadcrumb = (_, __) => null;
    options.beforeSend = (event, _) {
      event.user = null;
      event.request = null;
      event.message = null;
      // ignore: deprecated_member_use
      event.extra = null;
      event.breadcrumbs = null;
      for (final exception in event.exceptions ?? const []) {
        exception.value = null;
      }
      return event;
    };
  }, appRunner: appRunner);
}
