import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/theme/app_theme.dart';

void main() {
  test('textFaint meets 4.5:1 contrast on each palette surface', () {
    for (final (name, theme) in [
      ('AMOLED', AppTheme.amoled),
      ('charcoal', AppTheme.charcoal),
      ('light', AppTheme.light),
    ]) {
      final palette = AppPalette.forTheme(theme);
      final foreground = palette.textFaint.computeLuminance();
      for (final (surfaceName, surface) in [
        ('background', palette.background),
        ('card', palette.card),
      ]) {
        final background = surface.computeLuminance();
        final lighter = foreground > background ? foreground : background;
        final darker = foreground > background ? background : foreground;
        final contrast = (lighter + 0.05) / (darker + 0.05);
        expect(
          contrast,
          greaterThanOrEqualTo(4.5),
          reason: '$name textFaint on $surfaceName is $contrast:1',
        );
      }
    }
  });
}
