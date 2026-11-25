import 'dart:async';

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
  ///
  /// **Known platform quirk, discovered on real hardware:** the plugin's
  /// `authorize()` unconditionally calls Android's
  /// `ActivityCompat.requestPermissions`, then waits for
  /// `onRequestPermissionsResult`. On some Android versions/OEMs, if
  /// every requested permission is *already* granted (e.g. because
  /// `NearbyPermissions.requestAll` -- called first in `MeshOS.start` --
  /// already requested the same underlying `BLUETOOTH_*` permissions) --
  /// or, just as often in practice, already denied from a previous
  /// launch -- there's nothing new to prompt for and that callback
  /// simply never fires. With no timeout, `await ... .authorize()` would
  /// then hang forever, which previously hung the whole of
  /// `MeshOS.start()` (and, in turn, left a `mesh_console` freshly opened
  /// by the user on an endless loading spinner).
  ///
  /// The practical effect on real devices: since the *result* is already
  /// determined after the very first launch, `authorize()` hits this
  /// hang -- and eats its own timeout -- on **every subsequent launch**,
  /// not just the first, adding a fixed multi-second delay to every app
  /// start. [BluetoothLowEnergyManager.state] is a cheap, already-cached
  /// value (kept fresh by the plugin's own internal app-lifecycle
  /// observer, refreshed via a plain state query rather than a
  /// request-and-wait-for-a-result flow) that already reflects whether
  /// this app is authorized -- checking it first lets an already-decided
  /// outcome skip `authorize()` entirely, paying its cost only when the
  /// state is genuinely undetermined (effectively: the first time ever).
  static Future<bool> requestAll() async {
    final centralGranted = await _authorize(CentralManager());
    final peripheralGranted = await _authorize(PeripheralManager());
    return centralGranted && peripheralGranted;
  }

  static Future<bool> _authorize(BluetoothLowEnergyManager manager) async {
    switch (manager.state) {
      case BluetoothLowEnergyState.poweredOn:
      case BluetoothLowEnergyState.poweredOff:
        // Either way, the app is authorized -- `poweredOff` just means
        // the radio itself is switched off, a separate, unrelated
        // condition this permission check isn't responsible for.
        return true;
      case BluetoothLowEnergyState.unauthorized:
        return false;
      case BluetoothLowEnergyState.unknown:
      case BluetoothLowEnergyState.unsupported:
        break; // genuinely undetermined -- fall through to authorize().
    }
    try {
      return await manager.authorize().timeout(const Duration(seconds: 10));
    } catch (_) {
      return false;
    }
  }
}
