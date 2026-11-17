import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/sync_service.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/sync/sync_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../support/screenshot.dart';

Future<AppServices> servicesWithSync() async {
  final base = AppServices.inMemory();
  final identity = await DeviceIdentity.loadOrCreate(base.db);
  final sync = SyncService(
    repo: base.notes,
    peers: PeerStore(base.db),
    identity: identity,
    deviceName: base.settings.deviceName,
    port: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    enableDiscovery: false,
    localAddresses: () async => ['192.168.1.20', '100.88.1.5'],
  );
  return AppServices(base.db, base.notes, base.settings, '', sync: sync);
}

Future<void> pumpSync(
  WidgetTester tester,
  AppServices s, {
  Size size = const Size(412, 915),
}) async {
  await setWindow(tester, size);
  await tester.pumpWidget(
    AppScope(
      services: s,
      child: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(s.settings),
          home: const SyncScreen(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('empty state explains what sync is and offers pairing', (
    tester,
  ) async {
    final s = await servicesWithSync();
    addTearDown(s.close);
    await pumpSync(tester, s);
    expect(find.text('No paired devices'), findsOneWidget);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'nothing to sync with',
    );
    await screenshot(tester, 'sync_empty_phone');
  });

  testWidgets(
    'devices show status, pending changes and errors; rename and remove work',
    (tester) async {
      final s = await servicesWithSync();
      addTearDown(s.close);
      final sync = s.sync!;
      sync.peers.add(
        id: newDeviceId(),
        name: 'Nothing Phone',
        publicKey: randomBytes(32),
        endpoints: ['192.168.1.9:47380'],
      );
      final other = sync.peers.add(
        id: newDeviceId(),
        name: 'Desktop',
        publicKey: randomBytes(32),
      );
      s.notes.createNote(title: 'waiting');
      sync.peers.recordError(other.id, 'Desktop is not reachable right now.');
      await pumpSync(tester, s);
      expect(find.text('Paired devices (2 of 4)'), findsOneWidget);
      expect(find.text('Nothing Phone'), findsOneWidget);
      expect(find.textContaining('Not synced yet · 1 waiting'), findsOneWidget);
      expect(find.text('Desktop is not reachable right now.'), findsOneWidget);
      await screenshot(tester, 'sync_devices_phone');

      // Rename
      await tester.tap(find.byTooltip('Device options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Pixel');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Pixel'), findsOneWidget);

      // Remove, with confirmation
      await tester.tap(find.byTooltip('Device options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Notes already exchanged stay on both'),
        findsOneWidget,
      );
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(sync.peers.list().length, 1);
      expect(find.text('Paired devices (1 of 4)'), findsOneWidget);
    },
  );

  testWidgets('pairing is disabled once the device limit is reached', (
    tester,
  ) async {
    final s = await servicesWithSync();
    addTearDown(s.close);
    for (var i = 0; i < maxDevices - 1; i++) {
      s.sync!.peers.add(
        id: newDeviceId(),
        name: 'D$i',
        publicKey: randomBytes(32),
      );
    }
    await pumpSync(tester, s);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });

  testWidgets('desktop layout', (tester) async {
    final s = await servicesWithSync();
    addTearDown(s.close);
    s.sync!.peers.add(
      id: newDeviceId(),
      name: 'Nothing Phone (2)',
      publicKey: randomBytes(32),
    );
    await pumpSync(tester, s, size: const Size(1280, 800));
    await screenshot(tester, 'sync_desktop');
  });
}
