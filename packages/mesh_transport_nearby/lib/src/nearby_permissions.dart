import 'package:permission_handler/permission_handler.dart';

/// The Android runtime permissions Nearby Connections needs. Must be
/// granted before [NearbyTransport.startAdvertising] or
/// [NearbyTransport.startDiscovery] -- otherwise Nearby fails silently
/// (returns false) rather than throwing (ARCHITECTURE.md §11).
class NearbyPermissions {
  const NearbyPermissions._();

  static const List<Permission> required = [
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices, // Android 13+ (API 33)
    Permission.locationWhenInUse, // still required by Nearby on Android <12
  ];

  /// Requests every permission above and returns true only if all of them
  /// were granted.
  static Future<bool> requestAll() async {
    final statuses = await required.request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<bool> allGranted() async {
    for (final permission in required) {
      if (!await permission.isGranted) return false;
    }
    return true;
  }
}
