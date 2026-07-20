import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_console/mesh_simulator_screen.dart';

/// Exercises `MeshSimulatorScreen` through Flutter's real widget test
/// rendering pipeline -- as close to "does this actually work on a
/// device" as this project can get without one. Complements (does not
/// replace) `mesh_core`'s own protocol-level test suite: this proves the
/// screen wires MeshLink/FileTransferManager up correctly and renders
/// what it claims to; it says nothing about NearbyTransport/BleTransport.
///
/// Two non-obvious things every test here needs:
///
/// 1. A large test viewport. The screen's `ListView` only mounts
///    elements within its viewport (standard Sliver behavior, not a bug)
///    -- the test harness's default ~600px-tall viewport doesn't fit all
///    three node cards, so without enlarging it, Charlie's card (and
///    anything below it) would never appear in `find()` queries no
///    matter how long you wait. A real device's screen is taller and
///    scrollable, so this is purely a test-environment concern.
/// 2. Fixed-duration polling instead of `pumpAndSettle()`: several steps
///    inside the screen's async setup (the FakeTransport handshake
///    dance) don't call `setState` between awaits, so `pumpAndSettle`
///    (which only keeps pumping while new frames get scheduled) stops
///    advancing the fake clock before setup actually finishes.

void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxSteps = 80,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (var i = 0; i < maxSteps && !condition(); i++) {
    await tester.pump(step);
  }
}

bool _hasText(String substring) => find.textContaining(substring).evaluate().isNotEmpty;

void main() {
  testWidgets('sets up three nodes and renders them once ready', (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    // Every node already logged its handshake by the time setup
    // completes -- none of them are actually at "(no activity yet)".
    expect(find.text('(no activity yet)'), findsNothing);
    expect(find.textContaining('session established'), findsWidgets);
  });

  testWidgets('sending a message routes Alice -> Charlie via Bob and logs delivery', (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    await tester.tap(find.text('Send: Alice → Charlie (via Bob)'));
    await tester.pump();
    // Wait for the full end state -- Alice's "delivered" and Charlie's
    // own receipt log both need to have rendered, not just whichever one
    // happens first (they can land in different frames).
    await _pumpUntil(
      tester,
      () => _hasText('sendToNode(Charlie) -> delivered') && _hasText('message from'),
    );

    expect(find.textContaining('sendToNode(Charlie) -> delivered'), findsOneWidget);
    expect(find.textContaining('message from'), findsOneWidget);
  });

  testWidgets('broadcasting from Alice reaches Bob and Charlie', (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    await tester.tap(find.text('Broadcast from Alice'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => _hasText('broadcast sent') && find.textContaining('broadcast from').evaluate().length >= 2,
    );

    expect(find.textContaining('broadcast sent'), findsOneWidget);
    // Both Bob and Charlie should have surfaced the broadcast in their logs.
    expect(find.textContaining('broadcast from'), findsNWidgets(2));
  });

  testWidgets('sending a file completes and Charlie receives it', (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    await tester.tap(find.text('Send file: Alice → Charlie'));
    await tester.pump();
    await _pumpUntil(tester, () => _hasText('received file "demo.bin"'));

    expect(find.textContaining('received file "demo.bin"'), findsOneWidget);
  });

  testWidgets('taking Bob offline and back updates the toggle button and offline chip',
      (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    expect(find.text('Take Bob offline'), findsOneWidget);
    expect(find.text('offline'), findsNothing);

    await tester.tap(find.text('Take Bob offline'));
    await tester.pump();
    await _pumpUntil(tester, () => find.text('Bring Bob back').evaluate().isNotEmpty);

    expect(find.text('Bring Bob back'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);

    await tester.tap(find.text('Bring Bob back'));
    await tester.pump();
    await _pumpUntil(tester, () => find.text('Take Bob offline').evaluate().isNotEmpty);

    expect(find.text('Take Bob offline'), findsOneWidget);
    expect(find.text('offline'), findsNothing);
  });

  testWidgets('a message sent while Bob is offline still delivers once he reconnects '
      '(store-and-forward)', (tester) async {
    _useLargeViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MeshSimulatorScreen()));
    await _pumpUntil(tester, () => _hasText('Charlie'));

    await tester.tap(find.text('Take Bob offline'));
    await tester.pump();
    await _pumpUntil(tester, () => find.text('Bring Bob back').evaluate().isNotEmpty);

    await tester.tap(find.text('Send: Alice → Charlie (via Bob)'));
    await tester.pump();
    // Don't wait for it to resolve -- Alice's send is stuck with Bob
    // unreachable. The offline-toggle button uses its own busy flag
    // specifically so this doesn't deadlock it.
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Bring Bob back'));
    await tester.pump();
    await _pumpUntil(tester, () => _hasText('sendToNode(Charlie) -> delivered'), maxSteps: 120);

    expect(find.textContaining('sendToNode(Charlie) -> delivered'), findsOneWidget);
  });
}
