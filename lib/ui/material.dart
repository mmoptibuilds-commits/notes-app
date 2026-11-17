// Single import point for Material widgets.
//
// flutter_quill 11.x still builds on the SDK's `package:flutter/material.dart`,
// which Flutter deprecated in favour of `package:material_ui`. Mixing the two
// gives two unrelated `Theme`/`MaterialLocalizations` hierarchies, so the whole
// app stays on the SDK library until the editor migrates. See docs/DECISIONS.md.
// ignore_for_file: deprecated_member_use
export 'package:flutter/material.dart';
