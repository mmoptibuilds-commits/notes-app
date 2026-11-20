# Third-party licences

This inventory records the prior audit of the 112 hosted packages in
`pubspec.lock` plus the five Flutter SDK packages recorded there (117 packages
total). The SDK package licence is identified as Flutter’s BSD-3-Clause
licence as specified by that audit. The prior hosted-package classifications
were based on staged `LICENSE` text under
`.audit-input/licenses/<package>-<version>/`, not package metadata. That
staging directory was absent in this worktree, so the package classifications
were not independently rechecked here. “Direct” means listed in
`pubspec.yaml`; “transitive” means resolved through another dependency.

`*` means the licence has redistribution conditions: include the copyright and
licence terms and preserve required notices/disclaimers in source/binary
redistributions. Apache-2.0 also requires its licence text; preserve any
upstream `NOTICE` contents where applicable. These are permissive licences,
but still carry attribution/notice duties. `quiver` 3.2.2 includes a `NOTICE`
file in the supplied audit inputs. No copyleft, custom, unknown, or missing
licence text was identified in these package inputs.

| Package | Version | Dependency | Licence identified from text |
|---|---:|---|---|
| `flutter` | Flutter SDK 3.50.0 | direct main | BSD-3-Clause* |
| `flutter_localizations` | Flutter SDK 3.50.0 | transitive | BSD-3-Clause* |
| `flutter_test` | Flutter SDK 3.50.0 | direct dev | BSD-3-Clause* |
| `flutter_web_plugins` | Flutter SDK 3.50.0 | transitive | BSD-3-Clause* |
| `sky_engine` | Flutter SDK 3.50.0 | transitive | BSD-3-Clause* |
| `args` | 2.7.0 | transitive | BSD-3-Clause* |
| `async` | 2.13.1 | transitive | BSD-3-Clause* |
| `boolean_selector` | 2.1.2 | transitive | BSD-3-Clause* |
| `characters` | 1.4.1 | transitive | BSD-3-Clause* |
| `charcode` | 1.4.0 | transitive | BSD-3-Clause* |
| `clock` | 1.1.3 | transitive | Apache-2.0* |
| `code_assets` | 2.2.0 | transitive | BSD-3-Clause* |
| `collection` | 1.19.1 | transitive | BSD-3-Clause* |
| `cross_file` | 0.3.5+5 | transitive | BSD-3-Clause* |
| `crypto` | 3.0.8 | direct | BSD-3-Clause* |
| `cryptography` | 2.9.0 | direct | Apache-2.0* |
| `csslib` | 1.0.2 | transitive | BSD-3-Clause* |
| `dart_quill_delta` | 10.8.3 | direct | MIT* |
| `diff_match_patch` | 0.4.1 | transitive | Apache-2.0* |
| `fake_async` | 1.3.3 | direct | Apache-2.0* |
| `ffi` | 2.2.0 | transitive | BSD-3-Clause* |
| `ffi_leak_tracker` | 0.1.2 | transitive | BSD-3-Clause* |
| `file` | 7.0.1 | transitive | BSD-3-Clause* |
| `file_selector` | 1.1.0 | direct | BSD-3-Clause* |
| `file_selector_android` | 0.5.2+11 | transitive | Apache-2.0* |
| `file_selector_ios` | 0.5.3+7 | transitive | BSD-3-Clause* |
| `file_selector_linux` | 0.9.4+1 | transitive | BSD-3-Clause* |
| `file_selector_macos` | 0.9.5+2 | transitive | BSD-3-Clause* |
| `file_selector_platform_interface` | 2.7.0 | transitive | BSD-3-Clause* |
| `file_selector_web` | 0.9.5 | transitive | BSD-3-Clause* |
| `file_selector_windows` | 0.9.3+6 | transitive | BSD-3-Clause* |
| `flutter_colorpicker` | 1.1.0 | transitive | MIT* |
| `flutter_keyboard_visibility_linux` | 1.0.0 | transitive | MIT* |
| `flutter_keyboard_visibility_macos` | 1.0.0 | transitive | MIT* |
| `flutter_keyboard_visibility_platform_interface` | 2.0.0 | transitive | MIT* |
| `flutter_keyboard_visibility_temp_fork` | 0.1.6 | transitive | MIT* |
| `flutter_keyboard_visibility_windows` | 1.0.0 | transitive | MIT* |
| `flutter_lints` | 6.0.0 | direct | BSD-3-Clause* |
| `flutter_quill` | 11.6.0 | direct | MIT* |
| `flutter_quill_delta_from_html` | 1.5.3 | transitive | MIT* |
| `flutter_secure_storage` | 11.2.0 | direct | BSD-3-Clause* |
| `flutter_secure_storage_darwin` | 0.4.3 | transitive | BSD-3-Clause* |
| `flutter_secure_storage_linux` | 3.0.3 | transitive | BSD-3-Clause* |
| `flutter_secure_storage_platform_interface` | 2.1.1 | transitive | BSD-3-Clause* |
| `flutter_secure_storage_web` | 2.1.1 | transitive | BSD-3-Clause* |
| `flutter_secure_storage_windows` | 4.2.2 | transitive | BSD-3-Clause* |
| `flutter_staggered_grid_view` | 0.7.0 | direct | MIT* |
| `glob` | 2.2.0 | transitive | BSD-3-Clause* |
| `hooks` | 2.2.0 | transitive | BSD-3-Clause* |
| `html` | 0.15.7 | transitive | MIT* |
| `http` | 1.6.0 | transitive | BSD-3-Clause* |
| `http_parser` | 4.1.2 | transitive | BSD-3-Clause* |
| `intl` | 0.20.3 | transitive | BSD-3-Clause* |
| `is_ios_simulator` | 1.0.1 | transitive | MIT* |
| `jni` | 1.1.2 | transitive | BSD-3-Clause* |
| `jni_flutter` | 1.0.4+1 | transitive | BSD-3-Clause* |
| `jni_util` | 1.0.0 | transitive | BSD-3-Clause* |
| `leak_tracker` | 11.0.2 | transitive | BSD-3-Clause* |
| `leak_tracker_flutter_testing` | 3.0.10 | transitive | BSD-3-Clause* |
| `leak_tracker_testing` | 3.0.2 | transitive | BSD-3-Clause* |
| `lints` | 6.1.0 | transitive | BSD-3-Clause* |
| `listen` | 1.0.1 | transitive | BSD-3-Clause* |
| `logging` | 1.3.0 | transitive | BSD-3-Clause* |
| `markdown` | 7.3.1 | direct | BSD-3-Clause* |
| `markdown_quill` | 4.3.0 | direct | MIT* |
| `matcher` | 0.12.20 | transitive | BSD-3-Clause* |
| `material_color_utilities` | 0.13.0 | transitive | Apache-2.0* |
| `meta` | 1.19.0 | transitive | BSD-3-Clause* |
| `mobile_scanner` | 7.5.0 | direct | BSD-3-Clause* |
| `native_toolchain_c` | 0.19.6 | transitive | BSD-3-Clause* |
| `objective_c` | 9.6.4 | transitive | BSD-3-Clause* |
| `package_config` | 3.0.0 | transitive | BSD-3-Clause* |
| `path` | 1.9.1 | direct | BSD-3-Clause* |
| `path_provider` | 2.1.6 | direct | BSD-3-Clause* |
| `path_provider_android` | 2.3.1 | transitive | BSD-3-Clause* |
| `path_provider_foundation` | 2.6.0 | transitive | BSD-3-Clause* |
| `path_provider_linux` | 2.2.2 | transitive | BSD-3-Clause* |
| `path_provider_platform_interface` | 2.1.3 | transitive | BSD-3-Clause* |
| `path_provider_windows` | 2.3.0 | transitive | BSD-3-Clause* |
| `platform` | 3.2.0 | transitive | BSD-3-Clause* |
| `plugin_platform_interface` | 2.1.8 | transitive | BSD-3-Clause* |
| `process` | 5.0.6 | transitive | BSD-3-Clause* |
| `pub_semver` | 2.2.1 | transitive | BSD-3-Clause* |
| `qr` | 3.0.3 | transitive | BSD-3-Clause* |
| `qr_flutter` | 4.1.0 | direct | BSD-3-Clause* |
| `quill_native_bridge` | 11.2.0 | transitive | MIT* |
| `quill_native_bridge_android` | 0.0.2 | transitive | MIT* |
| `quill_native_bridge_ios` | 0.0.3 | transitive | MIT* |
| `quill_native_bridge_linux` | 0.0.3 | transitive | MIT* |
| `quill_native_bridge_macos` | 0.0.1 | transitive | MIT* |
| `quill_native_bridge_platform_interface` | 0.0.2+1 | transitive | MIT* |
| `quill_native_bridge_web` | 0.0.2 | transitive | MIT* |
| `quill_native_bridge_windows` | 0.1.1 | transitive | MIT* |
| `quiver` | 3.2.2 | transitive | Apache-2.0* (NOTICE file supplied) |
| `record_use` | 1.1.1 | transitive | BSD-3-Clause* |
| `source_span` | 1.10.2 | transitive | BSD-3-Clause* |
| `sqlite3` | 3.9.1 | direct | MIT* |
| `stack_trace` | 1.12.2 | transitive | BSD-3-Clause* |
| `stream_channel` | 2.1.4 | transitive | BSD-3-Clause* |
| `string_scanner` | 1.4.1 | transitive | BSD-3-Clause* |
| `term_glyph` | 1.2.2 | transitive | BSD-3-Clause* |
| `test_api` | 0.7.14 | transitive | BSD-3-Clause* |
| `typed_data` | 1.4.0 | transitive | BSD-3-Clause* |
| `url_launcher` | 6.3.3 | transitive | BSD-3-Clause* |
| `url_launcher_android` | 6.3.33 | transitive | BSD-3-Clause* |
| `url_launcher_ios` | 6.4.2 | transitive | BSD-3-Clause* |
| `url_launcher_linux` | 3.2.3 | transitive | BSD-3-Clause* |
| `url_launcher_macos` | 3.2.6 | transitive | BSD-3-Clause* |
| `url_launcher_platform_interface` | 2.3.2 | transitive | BSD-3-Clause* |
| `url_launcher_web` | 2.4.3 | transitive | BSD-3-Clause* |
| `url_launcher_windows` | 3.1.6 | transitive | BSD-3-Clause* |
| `vector_math` | 2.4.3 | transitive | BSD-3-Clause* |
| `vm_service` | 15.4.0 | transitive | BSD-3-Clause* |
| `web` | 1.1.2 | transitive | BSD-3-Clause* |
| `win32` | 6.4.0 | transitive | BSD-3-Clause* |
| `xdg_directories` | 1.1.0 | transitive | BSD-3-Clause* |
| `yaml` | 3.1.4 | transitive | MIT* |

## Bundled assets

- Atkinson Hyperlegible, Inter, JetBrains Mono, and Source Serif 4 font files
  each have a corresponding OFL licence text beside the font files in
  `assets/fonts/`. These texts identify the SIL Open Font License 1.1 (OFL-1.1).
  Keep the licence texts with redistributions of the fonts.
- The four bundled font licence files have a copyright notice and the OFL 1.1
  text. Inter's notice now says `(c) 2016 The Inter Project Authors`, matching
  the staged official Inter licence and font name-table metadata; it previously
  said 2020. The OFL includes the standard Reserved Font Name restriction, but
  the Inter licence names no specific Reserved Font Name. Notes uses the
  unmodified family name `Inter`.
- `tool/package_linux.sh` copies the four font licence files into the Linux
  release directory. No in-app licences page was found. The Android app
  bundles the font files but does not declare these text files as assets, so
  the Android APK does not currently provide a demonstrated, user-viewable
  copy of the font notices. Add an in-app or packaged notice before Android
  redistribution; this documentation cannot satisfy the APK's notice duty.
- The Linux package copies font OFL texts, but does not currently include this
  package inventory or all third-party package licence/NOTICE texts.
- `assets/icon/icon_512.png` and `assets/icon/icon_1024.png` have no source or
  licence documentation in the repository. Their provenance/licence is
  undocumented here.
- No separate licence/source documentation was found for other bundled
  artwork or generated icon assets. The asset inventory inspected was the
  repository’s `assets/` tree.

## Limits

This is a static inventory of the locked Dart/Flutter packages and staged
licence files, plus visible asset-side licence texts. It does not independently
verify the licence of every native binary or generated artefact supplied or
fetched by build hooks, Android Gradle plugins, the SDK, or the operating
system. No package was classified as unknown or missing based on the supplied
package inputs; that statement does not certify material outside those inputs.
