import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';

/// Loads the bundled fonts and Material icons so widget tests render real
/// text instead of placeholder boxes. Call once in `setUpAll`.
Future<void> loadAppFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
    }
    await loader.load();
  }

  const dir = 'assets/fonts';
  await load('Inter', ['$dir/Inter.ttf', '$dir/Inter-Italic.ttf']);
  await load('SourceSerif4', [
    '$dir/SourceSerif4.ttf',
    '$dir/SourceSerif4-Italic.ttf',
  ]);
  await load('JetBrainsMono', [
    '$dir/JetBrainsMono.ttf',
    '$dir/JetBrainsMono-Italic.ttf',
  ]);
  await load('AtkinsonHyperlegible', [
    '$dir/AtkinsonHyperlegible-Regular.ttf',
    '$dir/AtkinsonHyperlegible-Bold.ttf',
    '$dir/AtkinsonHyperlegible-Italic.ttf',
    '$dir/AtkinsonHyperlegible-BoldItalic.ttf',
  ]);
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

/// Sizes the test window in logical pixels. Phone: 412x915. Desktop: 1280x800.
Future<void> setWindow(
  WidgetTester tester,
  Size size, {
  double pixelRatio = 2,
}) async {
  tester.view.devicePixelRatio = pixelRatio;
  tester.view.physicalSize = size * pixelRatio;
  addTearDown(tester.view.reset);
}

/// Pumps the whole app over in-memory [services].
Future<void> pumpApp(WidgetTester tester, AppServices services) async {
  await tester.pumpWidget(NotesApp(services: services));
  await tester.pump();
}

/// Writes what is on screen to `build/screens/<name>.png` for visual review.
/// These are review artefacts, not golden comparisons.
Future<void> screenshot(WidgetTester tester, String name) async {
  final boundary = tester.binding.rootElement!.renderObject!;
  RenderRepaintBoundary? found;
  void visit(RenderObject o) {
    if (found != null) return;
    if (o is RenderRepaintBoundary) {
      found = o;
      return;
    }
    o.visitChildren(visit);
  }

  visit(boundary);
  final target = found!;
  await tester.runAsync(() async {
    final image = await target.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/screens/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
