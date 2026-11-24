import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/sync/cloud_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';

import 'support.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    AppServices services, {
    double width = 412,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 850);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: buildTheme(services.settings),
          home: const CloudScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('signed out explains privacy and offers browser sign in', (
    tester,
  ) async {
    final services = servicesWithCloud();
    addTearDown(services.close);
    await pump(tester, services);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.textContaining('not end-to-end encrypted'), findsOneWidget);
    expect(find.textContaining('LAN sync keeps working'), findsOneWidget);
  });

  testWidgets('wrong Google account explains the private server', (
    tester,
  ) async {
    final services = servicesWithCloud();
    addTearDown(services.close);
    (services.cloud! as FakeCloudService).failSignIn = true;
    await pump(tester, services);
    await tester.tap(find.text('Sign in with Google'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('This server is private'), findsOneWidget);
  });

  testWidgets('uploading state can resume its saved upload', (tester) async {
    final services = servicesWithCloud(phase: CloudPhase.uploading);
    addTearDown(services.close);
    await pump(tester, services);
    expect(
      find.text(
        'Upload is in progress. It can resume after you leave this screen.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Resume upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect((services.cloud! as FakeCloudService).uploads, 1);
  });

  testWidgets('unavailable build explains that cloud sync is unavailable', (
    tester,
  ) async {
    final services = servicesWithCloud(phase: CloudPhase.unavailable);
    addTearDown(services.close);
    await pump(tester, services);
    expect(
      find.text('Cloud sync is unavailable in this build.'),
      findsOneWidget,
    );
  });

  testWidgets('backup is required and upload asks explicit confirmation', (
    tester,
  ) async {
    final services = servicesWithCloud(phase: CloudPhase.signedIn);
    addTearDown(services.close);
    await pump(tester, services);
    expect(find.text('Upload this library'), findsNWidgets(2));
    expect(find.text('3 notes · 1 folder · 2 images · 1.5 KB'), findsOneWidget);
    final upload = find.widgetWithText(FilledButton, 'Upload this library');
    expect(tester.widget<FilledButton>(upload).onPressed, isNull);
    await tester.tap(find.text('Create verified backup'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('Verified: 3 notes'), findsOneWidget);
    await tester.tap(upload);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Upload'), findsOneWidget);
    expect(
      services.cloud is FakeCloudService
          ? (services.cloud! as FakeCloudService).uploads
          : 1,
      0,
    );
    await tester.tap(find.text('Upload').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect((services.cloud! as FakeCloudService).uploads, 1);
  });

  testWidgets('join only enabled for exact or empty device', (tester) async {
    final services = servicesWithCloud(phase: CloudPhase.signedIn);
    addTearDown(services.close);
    final cloud = services.cloud! as FakeCloudService;
    cloud.remoteLibrary = const CloudLibraryInfo(
      libraryId: 'test-library',
      state: 'ready',
      seq: 1,
      notes: 3,
      folders: 1,
      blobs: 2,
    );
    cloud.testReport = const JoinReport(
      identical: 1,
      onlyHere: 1,
      onlyThere: 0,
      differing: 1,
      missingAttachments: 0,
      folderReferenceErrors: 0,
    );
    await pump(tester, services);
    await tester.tap(find.widgetWithText(FilledButton, 'Check this device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('Only on this device: 1'), findsOneWidget);
    expect(
      find.text(
        'Both copies are untouched. Sync over LAN first, then check again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Join'), findsNothing);
  });

  testWidgets('ready state shows status, devices and controls', (tester) async {
    final services = servicesWithCloud(phase: CloudPhase.ready);
    addTearDown(services.close);
    final cloud = services.cloud! as FakeCloudService;
    cloud.testStatus = const CloudStatus(
      phase: CloudPhase.ready,
      pendingRows: 2,
    );
    await pump(tester, services, width: 1280);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Sync this device with the cloud'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text('Sign out of this device'), findsOneWidget);
  });

  testWidgets('renders themes at large text scale without overflow', (
    tester,
  ) async {
    for (final theme in AppTheme.values) {
      for (final size in [const Size(412, 850), const Size(1280, 850)]) {
        for (final scale in [1.4, 2.0]) {
          final services = servicesWithCloud(phase: CloudPhase.signedIn);
          addTearDown(services.close);
          services.settings.theme = theme;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: AppScope(
                services: services,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(services.settings),
                  home: const CloudScreen(),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(
            tester.takeException(),
            isNull,
            reason: '$theme $size scale $scale',
          );
        }
      }
    }
  });
}
