import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// The Android runtime permissions BLE central+peripheral roles need.
/// Must be granted before [BleTransport.startAdvertising] or
/// [BleTransport.startDiscovery] -- otherwise they fail silently rather
/// than throwing (ARCHITECTURE.md §11), same caveat as
/// `NearbyPermissions`.
///
/// Uses the plugin's own `authorize()` (its intended way to request
/// exactly the permissions its native Android code actually checks)
/// rather than a hand-maintained `permission_handler` list -- the
/// underlying manifest declarations (`BLUETOOTH_SCAN`,
/// `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`) are already present for
/// Nearby Connections and cover BLE too.
class BlePermissions {
  const BlePermissions._();

  /// Requests both the central and peripheral role's permissions and
  /// returns true only if both were granted.
  static Future<bool> requestAll() async {
    final centralGranted = await CentralManager().authorize();
    final peripheralGranted = await PeripheralManager().authorize();
    return centralGranted && peripheralGranted;
  }
}
