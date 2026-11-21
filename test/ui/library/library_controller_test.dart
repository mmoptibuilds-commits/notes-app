import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/library/library_controller.dart';

void main() {
  test('missing setting on an upgraded install starts in Unfiled', () {
    final app = AppServices.inMemory();
    final folder = app.notes.createFolder('Work');
    app.notes.createNote(title: 'Filed', folderId: folder.id);
    app.notes.createNote(title: 'Loose');
    expect(app.settings.read('startupView'), isNull);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(app.settings.startupView, StartupView.unfiled);
    expect(controller.unfiled, isTrue);
    expect(controller.folderId, isNull);
    expect(controller.items.map((item) => item.note.title), ['Loose']);
  });

  test('All startup view ignores the remembered folder', () {
    final app = AppServices.inMemory();
    final folder = app.notes.createFolder('Work');
    app.notes.createNote(title: 'Filed', folderId: folder.id);
    app.notes.createNote(title: 'Loose');
    app.settings.startupView = StartupView.all;
    app.settings.write(folderSettingKey, folder.id);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.unfiled, isFalse);
    expect(controller.folderId, isNull);
    expect(controller.items.map((item) => item.note.title).toSet(), {
      'Filed',
      'Loose',
    });
  });

  test('Last viewed restores a folder and persists each new selection', () {
    final app = AppServices.inMemory();
    final folder = app.notes.createFolder('Work');
    app.notes.createNote(title: 'Filed', folderId: folder.id);
    app.notes.createNote(title: 'Loose');
    app.settings.startupView = StartupView.last;
    app.settings.write(folderSettingKey, folder.id);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.folderId, folder.id);
    expect(controller.items.map((item) => item.note.title), ['Filed']);

    controller.selectFolder(unfiled: true);
    expect(app.settings.read(folderSettingKey), unfiledKey);
    expect(controller.unfiled, isTrue);
    expect(controller.items.map((item) => item.note.title), ['Loose']);
  });

  test('Last viewed with no remembered selection opens All', () {
    final app = AppServices.inMemory();
    final folder = app.notes.createFolder('Work');
    app.notes.createNote(title: 'Filed', folderId: folder.id);
    app.notes.createNote(title: 'Loose');
    app.settings.startupView = StartupView.last;

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.folderId, isNull);
    expect(controller.unfiled, isFalse);
    expect(controller.items, hasLength(2));
  });

  test('Last viewed restores a remembered Unfiled view', () {
    final app = AppServices.inMemory();
    app.notes.createFolder('Work');
    app.notes.createNote(title: 'Loose');
    app.settings.startupView = StartupView.last;
    app.settings.write(folderSettingKey, unfiledKey);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.unfiled, isTrue);
    expect(controller.folderId, isNull);
    expect(controller.items.map((item) => item.note.title), ['Loose']);
  });

  test('Unfiled without folders displays All and preserves its preference', () {
    final app = AppServices.inMemory();
    app.notes.createNote(title: 'Only note');
    app.settings.startupView = StartupView.unfiled;
    app.settings.write(folderSettingKey, unfiledKey);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.unfiled, isFalse);
    expect(controller.folderId, isNull);
    expect(controller.items.map((item) => item.note.title), ['Only note']);
    expect(app.settings.startupView, StartupView.unfiled);
    expect(app.settings.read('startupView'), 'unfiled');
    expect(app.settings.read(folderSettingKey), isNull);
  });

  test('deleted remembered folder falls back to All and clears its id', () {
    final app = AppServices.inMemory();
    final folder = app.notes.createFolder('Work');
    app.notes.createNote(title: 'Formerly filed', folderId: folder.id);
    app.settings.startupView = StartupView.last;
    app.settings.write(folderSettingKey, folder.id);
    app.notes.deleteFolder(folder.id);

    final controller = LibraryController(app.notes, app.settings);
    addTearDown(() {
      controller.dispose();
      app.close();
    });

    expect(controller.folderId, isNull);
    expect(controller.unfiled, isFalse);
    expect(controller.items.map((item) => item.note.title), ['Formerly filed']);
    expect(app.settings.read(folderSettingKey), isNull);
    expect(app.settings.startupView, StartupView.last);
  });
}
