import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/sync/cloud_screen.dart';

import 'cloud_scenario.dart' show CloudScenarioRole, TestCloudLogin;

const _firstNote = '00000000-0000-4000-8000-000000000211';
const _secondNote = '00000000-0000-4000-8000-000000000212';

/// Exercises first upload and join through the production CloudScreen.
Future<void> runCloudSetupUiScenario(
  WidgetTester tester,
  CloudScenarioRole role,
  Uri worker,
) async {
  final dataDir = await Directory.systemTemp.createTemp(
    'notes-cloud-setup-ui-',
  );
  AppServices? services;
  HttpCloudApi? api;
  CloudService? cloud;
  final sessions = MemoryCloudSessionStore();
  var activeStep = 'bootstrap';

  void pass(String name) {
    // ignore: avoid_print
    print('PASS $name');
  }

  Future<void> step(String name, Future<void> Function() action) async {
    activeStep = name.replaceAll(' ', '-');
    try {
      await action();
      pass(name);
    } on Object catch (error) {
      // ignore: avoid_print
      print('FAIL $name: $error');
      rethrow;
    }
  }

  Future<void> pumpUntil(
    String name,
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 500));
      if (await condition()) return;
    }
    throw StateError('Timed out waiting for $name.');
  }

  Future<void> tapText(String text, {bool last = false}) async {
    final matches = find.text(text);
    final finder = last ? matches.last : matches.first;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
  }

  try {
    final bootstrapped = await bootstrap(dataDir: dataDir.path);
    // Use the real encrypted database and settings, with isolated cloud
    // credentials and no LAN sync path.
    await bootstrapped.cloud?.stop();
    bootstrapped.cloud?.dispose();
    bootstrapped.sync?.dispose();
    final httpApi = HttpCloudApi(baseUrl: worker, sessions: sessions);
    api = httpApi;
    final cloudService = CloudService(
      repo: bootstrapped.notes,
      api: httpApi,
      sessions: sessions,
      dataDir: dataDir.path,
      deviceName: role == CloudScenarioRole.linux
          ? 'Linux setup UI test'
          : 'Android setup UI test',
      loginLauncher: TestCloudLogin(worker),
      unavailable: false,
    );
    cloud = cloudService;
    await step('sign in', () async {
      await cloudService.signIn();
      // The UI's first-upload panel is shown for an enabled, signed-in
      // service. With no library ID, NotesApp/CloudService.start() cannot
      // start a sync that could race the first upload.
      await cloudService.setEnabled(true);
    });
    services = AppServices(
      bootstrapped.db,
      bootstrapped.notes,
      bootstrapped.settings,
      dataDir.path,
      cloud: cloudService,
    );
    // This harness always starts with a fresh database, so explicitly skip
    // the first-run intro and keep the app's underlying route on the library.
    services.settings.completeOnboarding();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 850);
    await tester.pumpWidget(NotesApp(services: services));
    await tester.pump();
    // Open the real CloudScreen from the app's navigator. NotesApp starts the
    // cloud auto-sync engine just as it does in a normal launch.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const CloudScreen()),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    if (role == CloudScenarioRole.linux) {
      await step('L sees first-upload setup for empty library', () async {
        await pumpUntil(
          'first-upload setup',
          () async => find.text('Create verified backup').evaluate().isNotEmpty,
        );
        expect(find.text('Upload this library'), findsWidgets);
        expect(find.text('Could not check the cloud library.'), findsNothing);
      });

      await step('L creates synthetic library and uploads in UI', () async {
        final repo = services!.notes;
        final folder = repo.createFolder('Setup UI synthetic folder');
        repo.createNote(
          id: _firstNote,
          title: 'Setup UI synthetic note one',
          body: _body(['Initial synthetic body one']),
          folderId: folder.id,
        );
        repo.createNote(
          id: _secondNote,
          title: 'Setup UI synthetic note two',
          body: _body(['Initial synthetic body two']),
        );
        await tester.pump();
        await tapText('Create verified backup');
        await pumpUntil(
          'verified backup',
          () async =>
              find.textContaining('Verified: 2 notes').evaluate().isNotEmpty,
        );
        await tapText('Upload this library', last: true);
        await pumpUntil(
          'upload confirmation',
          () async => find.text('Upload this library?').evaluate().isNotEmpty,
        );
        await tapText('Upload');
        await pumpUntil('first upload becomes ready', () async {
          try {
            final ready = (await httpApi.library()).state == 'ready';
            return ready &&
                find
                    .text('Could not check the cloud library.')
                    .evaluate()
                    .isEmpty;
          } on CloudApiException catch (error) {
            if (error.kind == CloudErrorKind.notFound ||
                error.kind == CloudErrorKind.libraryMismatch) {
              return false;
            }
            rethrow;
          }
        }, timeout: const Duration(minutes: 5));
      });
    } else {
      await step('A waits for ready without the library error card', () async {
        await pumpUntil('server library becomes ready', () async {
          expect(find.text('Could not check the cloud library.'), findsNothing);
          try {
            final library = await httpApi.library();
            return library.state == 'ready' && library.notes >= 2;
          } on CloudApiException catch (error) {
            if (error.kind == CloudErrorKind.notFound ||
                error.kind == CloudErrorKind.libraryMismatch) {
              return false;
            }
            rethrow;
          }
        }, timeout: const Duration(minutes: 15));
        // The screen may have loaded the initial 404 before Linux uploads.
        // Reopening it performs a fresh library read for the join controls.
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.pop();
        await tester.pumpAndSettle();
        navigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const CloudScreen()),
        );
        await tester.pumpAndSettle();
        await pumpUntil(
          'device check UI',
          () async => find.text('Check this device').evaluate().isNotEmpty,
        );
        expect(find.text('Could not check the cloud library.'), findsNothing);
      });

      await step('A checks and joins through CloudScreen', () async {
        await tapText('Check this device', last: true);
        await pumpUntil(
          'join action',
          () async => find.text('Join').evaluate().isNotEmpty,
        );
        await tapText('Join');
        await pumpUntil(
          'join confirmation',
          () async => find.text('Join this device?').evaluate().isNotEmpty,
        );
        await tapText('Join', last: true);
        await pumpUntil(
          'join completion',
          () async =>
              find.text('This device joined.').evaluate().isNotEmpty ||
              find.text('Up to date').evaluate().isNotEmpty,
        );
        final folderedNote = services!.notes.getNote(_firstNote);
        expect(folderedNote, isNotNull);
        expect(folderedNote!.folderId, isNotNull);
        expect(
          services.notes.getFolderRecord(folderedNote.folderId!),
          isNotNull,
        );
        expect(services.notes.getNote(_secondNote), isNotNull);
      });
    }

    Object? libraryUiFailure;
    StackTrace? libraryUiStackTrace;
    if (role == CloudScenarioRole.android) {
      try {
        await step(
          'A sees joined unfiled synthetic note in library UI',
          () async {
            await tester.pageBack();
            await tester.pumpAndSettle();
            // A fresh install can return to the first-run introduction after
            // CloudScreen is popped. Dismiss it before checking the library.
            if (find.text('Skip').evaluate().isNotEmpty) {
              await tapText('Skip');
              await tester.pumpAndSettle();
            }
            await pumpUntil(
              'unfiled synthetic note in library',
              () async => find
                  .text('Setup UI synthetic note two')
                  .evaluate()
                  .isNotEmpty,
            );
          },
        );
      } on Object catch (error, stackTrace) {
        // Still run both edit-sync steps so this presentation check cannot
        // prevent the sync portion of the scenario from completing.
        libraryUiFailure = error;
        libraryUiStackTrace = stackTrace;
      }
    }

    await step('A edit syncs to L automatically', () async {
      if (role == CloudScenarioRole.android) {
        final note = services!.notes.getNote(_firstNote)!;
        services.notes.saveContent(
          _firstNote,
          title: 'Setup UI synthetic note one A edit',
          body: _body(['Android setup UI marker']),
          base: note.contentVv,
        );
        await cloud!.syncNow();
      } else {
        await pumpUntil(
          'Android edit reaches Linux repository',
          () async =>
              services!.notes.getNote(_firstNote)?.title ==
              'Setup UI synthetic note one A edit',
          timeout: const Duration(minutes: 5),
        );
      }
    });

    await step('L edit syncs to A automatically', () async {
      if (role == CloudScenarioRole.linux) {
        final note = services!.notes.getNote(_secondNote)!;
        services.notes.saveContent(
          _secondNote,
          title: 'Setup UI synthetic note two L edit',
          body: _body(['Linux setup UI marker']),
          base: note.contentVv,
        );
        await cloud!.syncNow();
      } else {
        await pumpUntil('Linux edit reaches Android repository', () async {
          await cloud!.syncNow();
          return services!.notes.getNote(_secondNote)?.title ==
              'Setup UI synthetic note two L edit';
        }, timeout: const Duration(minutes: 5));
        final note = services!.notes.getNote(_firstNote)!;
        const acknowledgementTitle = 'Setup UI synthetic note one A ack';
        services.notes.saveContent(
          _firstNote,
          title: acknowledgementTitle,
          body: _body(['Android setup UI acknowledgement']),
          base: note.contentVv,
        );
        // Establish a sequence boundary after the L edit reached this device;
        // then keep this process alive until the server exposes the ack row.
        final library = await api!.library();
        final since = library.seq;
        await cloud!.syncNow();
        await _waitForCloudNoteTitle(
          cloud!,
          api!,
          library.libraryId,
          since,
          _firstNote,
          acknowledgementTitle,
          timeout: const Duration(minutes: 5),
        );
      }
    });

    await step('L waits for Android acknowledgement', () async {
      if (role == CloudScenarioRole.linux) {
        await pumpUntil(
          'Android acknowledgement reaches Linux repository',
          () async {
            await cloud!.syncNow();
            return services!.notes.getNote(_firstNote)?.title ==
                'Setup UI synthetic note one A ack';
          },
          timeout: const Duration(minutes: 5),
        );
      }
    });

    if (libraryUiFailure != null) {
      Error.throwWithStackTrace(libraryUiFailure, libraryUiStackTrace!);
    }
  } catch (_) {
    // ignore: avoid_print
    print('FAIL scenario step=$activeStep');
    rethrow;
  } finally {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    if (cloud != null) {
      try {
        await cloud.signOut();
      } on Object {
        // Keep teardown moving if the test Worker is unavailable.
      }
      await cloud.stop();
    }
    api?.close();
    services?.close();
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  }
}

String _body(List<String> lines) => jsonEncode([
  for (final line in lines) {'insert': '$line\n'},
  {'insert': '\n'},
]);

Future<void> _waitForCloudNoteTitle(
  CloudService cloud,
  HttpCloudApi api,
  String libraryId,
  int since,
  String noteId,
  String title, {
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await cloud.syncNow();
    var cursor = since;
    while (true) {
      final changes = await api.changes(libraryId, cursor);
      if (changes.rows.any(
        (record) =>
            record.kind == 'note' &&
            record.id == noteId &&
            record.row['title'] == title,
      )) {
        return;
      }
      cursor = changes.next;
      if (!changes.more) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('Timed out waiting for cloud note title "$title".');
}
