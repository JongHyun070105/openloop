import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native platforms advertise a single-image share contract', () {
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final iosShareInfo = File(
      'ios/Share Extension/Info.plist',
    ).readAsStringSync();

    expect(androidManifest, contains('android.intent.action.SEND'));
    expect(
      androidManifest,
      isNot(contains('android.intent.action.SEND_MULTIPLE')),
    );
    expect(
      iosShareInfo,
      contains(
        '<key>NSExtensionActivationSupportsImageWithMaxCount</key>\n\t\t\t\t<integer>1</integer>',
      ),
    );
  });
}
