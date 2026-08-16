import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

abstract final class InstallationIdentity {
  static const _key = 'anonymous_installation_id';
  static String? _cached;

  static Future<String> get() async {
    if (_cached case final value?) return value;
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_key);
    if (existing?.isNotEmpty == true) return _cached = existing!;
    final created = const Uuid().v4();
    await preferences.setString(_key, created);
    return _cached = created;
  }
}
