import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/open_loop.dart';

abstract interface class DeviceActions {
  Future<bool> addToCalendar(OpenLoop loop);
  Future<bool> scheduleReminder(OpenLoop loop);
}

class NativeDeviceActions implements DeviceActions {
  NativeDeviceActions({FlutterLocalNotificationsPlugin? notifications})
    : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _notifications;
  bool _initialized = false;

  @override
  Future<bool> addToCalendar(OpenLoop loop) async {
    final start = loop.startsAt;
    if (start == null) return false;
    try {
      return await Add2Calendar.addEvent2Cal(
        Event(
          title: loop.title,
          description: loop.purpose ?? loop.resolutionNote,
          location: loop.place,
          startDate: start,
          endDate: start.add(
            loop.kind == LoopKind.deadline
                ? const Duration(minutes: 30)
                : const Duration(hours: 1),
          ),
        ),
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
        iOS: DarwinInitializationSettings(),
      ),
    );
    _initialized = true;
  }

  @override
  Future<bool> scheduleReminder(OpenLoop loop) async {
    final eventTime = loop.startsAt;
    if (eventTime == null) return false;
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

      var reminderAt = eventTime.subtract(
        loop.kind == LoopKind.deadline
            ? const Duration(days: 1)
            : const Duration(hours: 1),
      );
      if (!reminderAt.isAfter(DateTime.now())) {
        reminderAt = DateTime.now().add(const Duration(seconds: 5));
      }
      await _notifications.zonedSchedule(
        loop.id.hashCode & 0x7fffffff,
        loop.kind == LoopKind.deadline ? '마감이 다가옵니다' : '곧 일정이 시작됩니다',
        loop.title,
        tz.TZDateTime.from(reminderAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'openloop_reminders',
            'OpenLoop reminders',
            channelDescription: 'OpenLoop 일정과 마감 알림',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class NoopDeviceActions implements DeviceActions {
  @override
  Future<bool> addToCalendar(OpenLoop loop) async => true;
  @override
  Future<bool> scheduleReminder(OpenLoop loop) async => true;
}
