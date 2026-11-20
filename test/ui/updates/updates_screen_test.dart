import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/update_http.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/updates/updates_screen.dart';

import '../../support/screenshot.dart';
import '../../update/fake_http.dart';
import '../../update/world.dart';

void main() {
  setUpAll(loadAppFonts);

  late World w;
  late AppServices services;

  Future<void> create({
    UpdatePlatform platform = linuxPlatform,
    bool pinKey = true,
  }) async {
    w = await World.create(platform: platform, pinKey: pinKey);
    services = AppServices.inMemory();
    addTearDown(() {
      w.dispose();
      services.close();
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    double textScale = 1,
    bool pushed = false,
  }) async {
    await setWindow(tester, size);
    final screen = UpdatesScreen(
      controller: w.controller,
      settings: services.settings,
      clock: () => w.now,
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(services.settings),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: pushed
            ? Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => screen)),
                      child: const Text('open updates'),
                    ),
                  ),
                ),
              )
            : screen,
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> run(WidgetTester tester, Future<void> Function() f) async {
    await tester.runAsync(f);
    await settle(tester);
  }

  // Each state reached by driving the real controller against fakes.
  final states =
      <String, ({Future<void> Function(WidgetTester) setUp, String expect})>{
        'idle': (setUp: (t) async {}, expect: 'Updates have not been checked'),
        'checking': (
          setUp: (t) async {
            w.installer.gate = Completer<void>();
            unawaited(w.controller.check());
            await settle(t);
          },
          expect: 'Checking for updates',
        ),
        'up to date': (
          setUp: (t) async {
            await w.publish(version: '1.0.0', build: 20261122);
            await run(t, w.controller.check);
          },
          expect: 'Notes is up to date',
        ),
        'no stable release': (
          setUp: (t) async {
            w.http.on(w.apiUrl, FakeReply(404));
            await run(t, w.controller.check);
          },
          expect: 'No stable release published',
        ),
        'offline': (
          setUp: (t) async {
            w.http.on(
              w.apiUrl,
              FakeReply(0, error: const UpdateOfflineException()),
            );
            await run(t, w.controller.check);
          },
          expect: 'Cannot reach GitHub',
        ),
        'check failed': (
          setUp: (t) async {
            w.http.on(w.apiUrl, FakeReply(500));
            await run(t, w.controller.check);
          },
          expect: 'The update check failed',
        ),
        'rate limited': (
          setUp: (t) async {
            w.http.on(
              w.apiUrl,
              FakeReply(429, headers: {'retry-after': '600'}),
            );
            await run(t, w.controller.check);
          },
          expect: 'GitHub is limiting requests',
        ),
        'available': (
          setUp: (t) async {
            await w.publish();
            await run(t, w.controller.check);
          },
          expect: 'Version 1.0.1 is available',
        ),
        'downloading': (
          setUp: (t) async {
            await w.publish();
            await run(t, w.controller.check);
            w.installer.gate = Completer<void>();
            await t.runAsync(() async => unawaited(w.controller.download()));
            await settle(t);
          },
          expect: 'Downloading version 1.0.1',
        ),
        'ready to install': (
          setUp: (t) async {
            await w.publish();
            await run(t, w.controller.check);
            await run(t, w.controller.download);
          },
          expect: 'Version 1.0.1 is ready to install',
        ),
        'verification failed': (
          setUp: (t) async {
            await w.publish(sigKeyId: 'other');
            await run(t, w.controller.check);
          },
          expect: 'Could not verify the update',
        ),
        'blocked (unmanaged)': (
          setUp: (t) async {
            w.installer.block = const UpdateBlock(
              BlockKind.unmanagedInstall,
              'Not a managed install. Run install.sh from the archive.',
            );
            await w.publish();
            await run(t, w.controller.check);
          },
          expect: 'cannot be installed from here',
        ),
        'handed to the OS': (
          setUp: (t) async {
            await w.publish();
            await run(t, w.controller.check);
            await run(t, w.controller.download);
            await run(t, w.controller.install);
          },
          expect: 'restarting to finish the update',
        ),
      };

  for (final entry in states.entries) {
    for (final size in const [
      Size(320, 640),
      Size(412, 915),
      Size(1440, 900),
    ]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets(
          '${entry.key} at ${size.width.toInt()}px, text x${scale.toInt()}: '
          'no overflow',
          (tester) async {
            await create();
            await pump(tester, size: size, textScale: scale);
            await entry.value.setUp(tester);
            expect(find.textContaining(entry.value.expect), findsOneWidget);
            expect(tester.takeException(), isNull);
            // A live region carries the status for screen readers.
            final handle = tester.ensureSemantics();
            final live = tester.getSemantics(
              find.textContaining(entry.value.expect),
            );
            expect(
              live.getSemanticsData().flagsCollection.isLiveRegion ||
                  _hasLiveAncestor(
                    tester,
                    find.textContaining(entry.value.expect),
                  ),
              isTrue,
            );
            handle.dispose();
            if (entry.value.setUp == states['downloading']!.setUp ||
                entry.value.setUp == states['checking']!.setUp) {
              w.installer.gate?.complete();
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)),
              );
              await settle(tester);
            }
          },
        );
      }
    }
  }

  group('behaviour', () {
    testWidgets('no stable release is never shown as up to date', (
      tester,
    ) async {
      await create();
      w.http.on(w.apiUrl, FakeReply(404));
      await pump(tester);
      await run(tester, w.controller.check);
      expect(find.text('No stable release published'), findsOneWidget);
      expect(find.textContaining('up to date'), findsNothing);
      await screenshot(tester, 'updates_no_stable_phone');
    });

    testWidgets('Check for updates runs a check and shows the result', (
      tester,
    ) async {
      await create();
      await w.publish(version: '1.0.0', build: 20261122);
      await pump(tester);
      expect(find.text('Not checked yet'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Check for updates'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await settle(tester);
      expect(find.text('Notes is up to date'), findsOneWidget);
      expect(find.textContaining('Last checked: just now'), findsOneWidget);
    });

    testWidgets('available update shows details and notes; Download proceeds', (
      tester,
    ) async {
      await create();
      await w.publish(notes: 'Line one\n\n\n\nLine two');
      await pump(tester);
      await run(tester, w.controller.check);
      expect(find.textContaining('Version 1.0.1  ·  '), findsOneWidget);
      expect(find.text('Line one\n\nLine two'), findsOneWidget);
      await screenshot(tester, 'updates_available_phone');
      await tester.runAsync(() async {
        await tester.tap(find.text('Download'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.textContaining('is ready to install'), findsOneWidget);
      expect(find.text('Install…'), findsOneWidget);
      await screenshot(tester, 'updates_ready_phone');
    });

    testWidgets('Cancel stops a download and returns to Download', (
      tester,
    ) async {
      await create();
      await w.publish();
      await pump(tester);
      await run(tester, w.controller.check);
      w.installer.gate = Completer<void>();
      await tester.runAsync(() async => unawaited(w.controller.download()));
      await settle(tester);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      w.installer.gate!.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await settle(tester);
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets(
      'Install asks for confirmation naming the version and the restart',
      (tester) async {
        await create();
        await w.publish();
        await pump(tester);
        await run(tester, w.controller.check);
        await run(tester, w.controller.download);
        await tester.tap(find.text('Install…'));
        await tester.pumpAndSettle();
        expect(find.text('Install version 1.0.1?'), findsOneWidget);
        expect(
          find.textContaining('close, update itself and reopen'),
          findsOne,
        );
        // Cancel: nothing installed.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(w.installer.installs, 0);
        // Confirm: handed over, never "success".
        await tester.tap(find.text('Install…'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Install'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await settle(tester);
        expect(w.installer.installs, 1);
        expect(find.textContaining('restarting'), findsOneWidget);
        expect(find.textContaining('Updated to'), findsNothing);
        expect(find.textContaining('success'), findsNothing);
      },
    );

    testWidgets('the Android confirmation says Android will ask again', (
      tester,
    ) async {
      await create(platform: androidPlatform);
      await w.publish();
      await pump(tester);
      await run(tester, w.controller.check);
      await run(tester, w.controller.download);
      await tester.tap(find.text('Install…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Android will ask you to confirm'), findsOne);
    });

    testWidgets(
      'Android without install permission offers settings and retry',
      (tester) async {
        await create(platform: androidPlatform);
        await w.publish();
        await pump(tester);
        await run(tester, w.controller.check);
        await run(tester, w.controller.download);
        w.installer.installResult = const InstallNeedsPermission();
        await run(tester, w.controller.install);
        expect(find.text('Open Android settings'), findsOneWidget);
        expect(find.textContaining('come back and press Try again'), findsOne);
        await tester.tap(find.text('Open Android settings'));
        await tester.pump();
        expect(w.installer.settingsOpened, 1);
        expect(w.installer.installs, 1, reason: 'no automatic retry');
      },
    );

    testWidgets('Android: a dismissed system dialog offers Install again', (
      tester,
    ) async {
      await create(platform: androidPlatform);
      await w.publish();
      await pump(tester);
      await run(tester, w.controller.check);
      await run(tester, w.controller.download);
      w.installer.installResult = const InstallHandedToOs(willRestart: false);
      await run(tester, w.controller.install);
      expect(find.textContaining('Waiting for Android'), findsOneWidget);
      expect(find.text('Install again'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Check again'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Install again'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Install'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);
      expect(w.installer.installs, 2);
    });

    testWidgets('Linux: restarting hand-over has no actions', (tester) async {
      await create();
      await w.publish();
      await pump(tester);
      await run(tester, w.controller.check);
      await run(tester, w.controller.download);
      await run(tester, w.controller.install);
      expect(find.text('Install again'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('Android unsigned metadata is disclosed', (tester) async {
      await create(platform: androidPlatform, pinKey: false);
      await w.publish(sign: false);
      await pump(tester);
      await run(tester, w.controller.check);
      expect(find.textContaining('information is not signed yet'), findsOne);
    });

    testWidgets('Linux with no signing key: blocked guidance, no Download', (
      tester,
    ) async {
      await create(pinKey: false);
      await w.publish(sign: false);
      await pump(tester);
      await run(tester, w.controller.check);
      expect(find.textContaining('signing key has not been set up'), findsOne);
      expect(find.text('Download'), findsNothing);
      await screenshot(tester, 'updates_blocked_phone');
    });

    testWidgets('a failed download offers Retry that resumes the download', (
      tester,
    ) async {
      await create();
      await w.publish();
      await pump(tester);
      await run(tester, w.controller.check);
      w.http.replace(
        assetUrl('1.0.1', 'notes-1.0.1-linux-x64.tar.gz'),
        FakeReply(404),
      );
      await run(tester, w.controller.download);
      expect(find.text('The update failed'), findsOneWidget);
      await w.publish();
      await tester.runAsync(() async {
        await tester.tap(find.text('Retry'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.textContaining('is ready to install'), findsOneWidget);
    });

    testWidgets(
      'an install result from the last launch is shown and dismissible',
      (tester) async {
        await create();
        w.installer.outcome = const InstallOutcome(
          id: 'x',
          updated: true,
          version: '1.0.1',
          message: 'Updated to 1.0.1.',
        );
        await pump(tester);
        await run(tester, w.controller.resolveLastInstall);
        expect(find.text('Updated to 1.0.1.'), findsOneWidget);
        await tester.tap(find.byTooltip('Dismiss'));
        await tester.pump();
        expect(find.text('Updated to 1.0.1.'), findsNothing);
      },
    );

    testWidgets('the automatic check switch is bound to the setting', (
      tester,
    ) async {
      await create();
      await pump(tester);
      expect(services.settings.autoCheckUpdates, isTrue);
      expect(find.textContaining('No personal data is sent'), findsOneWidget);
      expect(find.textContaining('api.github.com'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(services.settings.autoCheckUpdates, isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('long release notes are truncated safely', (tester) async {
      await create();
      await w.publish(notes: '${'word ' * 2000}\u0000end');
      await pump(tester);
      await run(tester, w.controller.check);
      final text = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .single
          .data!;
      expect(text.length, lessThanOrEqualTo(kMaxNotesShown + 1));
      expect(text, endsWith('…'));
      expect(text.contains('\u0000'), isFalse);
    });

    testWidgets('content is bounded in width on a wide window', (tester) async {
      await create();
      await pump(tester, size: const Size(1440, 900));
      final card = tester.getSize(find.byType(Material).at(1));
      expect(card.width, lessThanOrEqualTo(640));
    });
  });

  group('Escape and back', () {
    testWidgets('Escape goes back exactly one level', (tester) async {
      await create();
      await pump(tester, pushed: true);
      await tester.tap(find.text('open updates'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesScreen), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesScreen), findsNothing);
      expect(find.text('open updates'), findsOneWidget);
    });

    testWidgets('Escape with the confirm dialog open closes only the dialog', (
      tester,
    ) async {
      await create();
      await w.publish();
      await pump(tester, pushed: true);
      await tester.tap(find.text('open updates'));
      await tester.pumpAndSettle();
      await run(tester, w.controller.check);
      await run(tester, w.controller.download);
      await tester.tap(find.text('Install…'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(UpdatesScreen), findsOneWidget);
      expect(w.installer.installs, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesScreen), findsNothing);
    });

    testWidgets('the back button in the app bar goes back', (tester) async {
      await create();
      await pump(tester, pushed: true);
      await tester.tap(find.text('open updates'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesScreen), findsNothing);
    });
  });

  group('helpers', () {
    test(
      'displayNotes collapses blank lines and strips control characters',
      () {
        expect(displayNotes('a\r\n\r\n\r\n\r\nb\u0007c'), 'a\n\nbc');
        expect(displayNotes('   '), '');
      },
    );

    test('displayNotes does not split a surrogate pair', () {
      final s = '${'a' * 9}😀tail';
      final cut = displayNotes(s, limit: 10);
      expect(cut, '${'a' * 9}…');
    });

    test('formatSize', () {
      expect(formatSize(500), '1 KB');
      expect(formatSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatSize(41 * 1024 * 1024 + 300 * 1024), '41.3 MB');
    });
  });
}

bool _hasLiveAncestor(WidgetTester tester, Finder f) {
  var node = tester.getSemantics(f);
  SemanticsNode? n = node;
  while (n != null) {
    if (n.getSemanticsData().flagsCollection.isLiveRegion) return true;
    n = n.parent;
  }
  return false;
}
