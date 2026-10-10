import 'package:flatkit/flatkit.dart';
import 'package:flutter/widgets.dart';

/// Monospace text for package names, versions and builds, like the TUI.
const String monoFamily = 'monospace';
const List<String> monoFallback = [
  'JetBrains Mono',
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Courier New',
];

TextStyle mono(BuildContext context,
    {double? size, Color? color, FontWeight? weight}) {
  return KitText.body(context).copyWith(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: size ?? 13,
    color: color,
    fontWeight: weight,
    height: 1.3,
  );
}

/// The small dim text used for counts, hints and secondary details.
TextStyle dim(BuildContext context) => KitText.dim(context, small: true);
