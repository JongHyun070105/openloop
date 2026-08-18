import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/open_loop.dart';

typedef CalendarLauncher = Future<bool> Function(Event event);

abstract interface class DeviceActions {
  Future<bool> addToCalendar(OpenLoop loop);
  Future<bool> requestNotificationPermission();
  Future<bool> syncReminders(Iterable<OpenLoop> loops);
  Future<bool> scheduleReminder(OpenLoop loop);
  Future<void> showNotification({
    required String title,
    required String body,
    String? subtitle,
  });
  Future<void> cancelReminders(OpenLoop loop);
}

class NativeDeviceActions implements DeviceActions {
  NativeDeviceActions({
    FlutterLocalNotificationsPlugin? notifications,
    CalendarLauncher? calendarLauncher,
    this.calendarHandoffTimeout = const Duration(seconds: 1),
  }) : _notifications = notifications ?? FlutterLocalNotificationsPlugin(),
       _calendarLauncher = calendarLauncher ?? Add2Calendar.addEvent2Cal;

  final FlutterLocalNotificationsPlugin _notifications;
  final CalendarLauncher _calendarLauncher;
  final Duration calendarHandoffTimeout;
  bool _initialized = false;

  @override
  Future<bool> addToCalendar(OpenLoop loop) async {
    final start = loop.startsAt;
    if (start == null) return false;
    try {
      final launched = _calendarLauncher(
        Event(
          title: loop.title,
          description: loop.summary ?? loop.purpose ?? loop.resolutionNote,
          location: loop.place,
          startDate: start,
          endDate: start.add(
            loop.kind == LoopKind.deadline
                ? const Duration(minutes: 30)
                : const Duration(hours: 1),
          ),
        ),
      );
      // iOS's composer is an OS-owned screen. Some versions of the native
      // plugin never complete their method callback after presenting it, so
      // this bounded result means a successful handoff cannot freeze Flutter.
      return await launched.timeout(
        calendarHandoffTimeout,
        onTimeout: () => true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
          defaultPresentAlert: true,
          defaultPresentBadge: true,
          defaultPresentSound: true,
          defaultPresentBanner: true,
          defaultPresentList: true,
        ),
      ),
    );
    _initialized = true;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      await _initialize();
      final android = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final ios = _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final androidGranted = await android?.requestNotificationsPermission();
      final iosGranted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      if (androidGranted == false || iosGranted == false) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> syncReminders(Iterable<OpenLoop> loops) async {
    try {
      await _initialize();
      final now = DateTime.now();
      var scheduledAny = false;
      for (final loop in loops) {
        await cancelReminders(loop);
        if (loop.state == LoopState.closed) continue;
        for (final checkpoint in loop.checkpoints) {
          final dueAt = checkpoint.dueAt?.toLocal();
          if (checkpoint.completed || dueAt == null || !dueAt.isAfter(now)) {
            continue;
          }
          await _notifications.zonedSchedule(
            _notificationId(loop.id, checkpoint.id),
            switch (loop.kind) {
              LoopKind.appointment => '일정 확인 시간입니다',
              LoopKind.deadline => '마감 확인 시간입니다',
              LoopKind.coupon => '쿠폰 기한 확인 시간입니다',
              LoopKind.purchase => '반품·보증 기한 확인 시간입니다',
              LoopKind.reservation => '예약 확인 시간입니다',
              LoopKind.place => '저장한 장소입니다',
            },
            checkpoint.title,
            // TZDateTime needs an absolute instant. Passing a local DateTime
            // to an unconfigured tz.local can shift the reminder to UTC.
            tz.TZDateTime.from(dueAt.toUtc(), tz.UTC),
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'openloop_reminders',
                'OpenLoop reminders',
                channelDescription: 'OpenLoop 일정과 마감 알림',
                importance: Importance.high,
                priority: Priority.high,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
                presentBanner: true,
                presentList: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
          scheduledAny = true;
        }
      }
      return scheduledAny;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> scheduleReminder(OpenLoop loop) => syncReminders([loop]);

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? subtitle,
  }) async {
    await _initialize();
    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          'openloop_reminders',
          'OpenLoop reminders',
          channelDescription: 'OpenLoop 일정과 마감 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          subtitle: subtitle,
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          presentBanner: true,
          presentList: true,
        ),
      ),
    );
  }

  @override
  Future<void> cancelReminders(OpenLoop loop) async {
    await _initialize();
    for (final checkpoint in loop.checkpoints) {
      await _notifications.cancel(_notificationId(loop.id, checkpoint.id));
    }
  }
}

int _notificationId(String loopId, String checkpointId) {
  // Stable FNV-1a hash: Dart's String.hashCode is deliberately not a durable
  // storage key across app launches, while notification IDs must be.
  var hash = 0x811c9dc5;
  for (final codeUnit in '$loopId/$checkpointId'.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

class NoopDeviceActions implements DeviceActions {
  @override
  Future<bool> addToCalendar(OpenLoop loop) async => true;
  @override
  Future<bool> requestNotificationPermission() async => true;
  @override
  Future<bool> syncReminders(Iterable<OpenLoop> loops) async => true;
  @override
  Future<bool> scheduleReminder(OpenLoop loop) async => true;
  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? subtitle,
  }) async {}
  @override
  Future<void> cancelReminders(OpenLoop loop) async {}
}
