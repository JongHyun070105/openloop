import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';
import 'config.dart';
import 'services/device_actions.dart';
import 'services/external_integrations.dart';
import 'services/loop_repository.dart';

export 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runWithObservability(() async {
    runApp(
      OpenLoopApp(
        controller: AppController(
          repository: SharedPreferencesLoopRepository(),
          deviceActions: NativeDeviceActions(),
        ),
      ),
    );
    unawaited(
      AppIntegrations.instance.initialize(
        apiBaseUrl: configuredOpenLoopApiBaseUrl,
      ),
    );
  });
}
