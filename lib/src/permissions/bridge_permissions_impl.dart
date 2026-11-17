import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import '../interfaces/bridge_permissions.dart';

/// Runtime permission helper for Android scan / advertise flows.
///
/// Apple platforms rely on Info.plist / entitlements; BLE plugins also
/// trigger system prompts when APIs are first used.
class BridgePermissionsImpl implements BridgePermissions {
  @override
  Future<bool> ensureScanPermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );
  }

  @override
  Future<bool> ensureHostPermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );
  }
}
