import 'package:flutter/cupertino.dart';

import '../data/models.dart';

/// Design tokens transcribed from the approved Figma Make file.
///
/// The Figma is the visual direction only; the schema and the accepted product
/// decisions remain authoritative for behaviour and data (see docs/DECISIONS.md).
/// These are the iOS system colours the mockup uses, expressed as ARGB constants
/// so no runtime alpha API is needed — withOpacity is deprecated on newer SDKs
/// and withValues does not exist on older ones.
class AppColors {
  const AppColors._();

  static const Color blue = Color(0xFF007AFF);
  static const Color green = Color(0xFF34C759);
  static const Color red = Color(0xFFFF3B30);

  /// systemGroupedBackground
  static const Color background = Color(0xFFF2F2F7);
  static const Color card = Color(0xFFFFFFFF);

  static const Color label = Color(0xFF000000);

  /// secondaryLabel — rgba(60,60,67,0.6)
  static const Color label2 = Color(0x993C3C43);

  /// tertiaryLabel — rgba(60,60,67,0.3)
  static const Color label3 = Color(0x4D3C3C43);

  /// separator — rgba(60,60,67,0.18)
  static const Color separator = Color(0x2E3C3C43);

  /// fill — rgba(120,120,128,0.2)
  static const Color fill = Color(0x33787880);

  /// systemGreen at 15%, precomputed.
  static const Color greenTint = Color(0x2634C759);

  /// blue at 10%, precomputed — the sign-in logo tile.
  static const Color blueTint = Color(0x1A007AFF);
}

/// Figma metrics.
class AppMetrics {
  const AppMetrics._();

  static const double cardRadius = 14;
  static const double buttonRadius = 14;
  static const double buttonHeight = 52;
  static const double rowHeight = 44;
  static const double signInRowHeight = 50;
  static const double gutter = 16;
}

const CupertinoThemeData appTheme = CupertinoThemeData(
  brightness: Brightness.light,
  primaryColor: AppColors.blue,
  scaffoldBackgroundColor: AppColors.background,
  barBackgroundColor: AppColors.card,
);

/// The FieldProof shield mark, drawn from the Figma vector so the app needs no
/// SVG dependency. Source viewBox is 44x44.
class ShieldMark extends StatelessWidget {
  const ShieldMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ShieldPainter()),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 44.0;
    canvas.scale(scale);

    final shield = Path()
      ..moveTo(22, 3)
      ..lineTo(4, 11)
      ..lineTo(4, 21)
      ..cubicTo(4, 31.5, 12.2, 41.1, 22, 44)
      ..cubicTo(31.8, 41.1, 40, 31.5, 40, 21)
      ..lineTo(40, 11)
      ..close();
    canvas.drawPath(shield, Paint()..color = AppColors.blue);

    final tick = Path()
      ..moveTo(15, 22)
      ..lineTo(19.5, 26.5)
      ..lineTo(29, 17);
    canvas.drawPath(
      tick,
      Paint()
        ..color = AppColors.card
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Uppercase grouped-list section header: 13/600, 0.4 tracking.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppMetrics.gutter,
        22,
        AppMetrics.gutter,
        6,
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.label2,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// White grouped card, 14pt radius, hairline border.
class InsetCard extends StatelessWidget {
  const InsetCard({
    super.key,
    required this.children,
    this.separatorInset = 16,
    this.horizontalMargin = AppMetrics.gutter,
  });

  final List<Widget> children;
  final double separatorInset;
  final double horizontalMargin;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: separatorInset),
            color: AppColors.separator,
          ),
        );
      }
      rows.add(children[i]);
    }

    return Container(
      margin: EdgeInsets.symmetric(horizontal: horizontalMargin),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        border: Border.all(color: AppColors.separator, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// Label left, value right-aligned — the iOS grouped-form convention.
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.label,
    required this.controller,
    this.placeholder,
    this.keyboardType,
    this.obscureText = false,
    this.autofocus = false,
    this.labelWidth = 100,
    this.height = AppMetrics.rowHeight,
    this.errorText,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String? placeholder;
  final TextInputType? keyboardType;
  final bool obscureText;
  final bool autofocus;
  final double labelWidth;
  final double height;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
          child: Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 17, color: AppColors.label),
                ),
              ),
              Expanded(
                child: CupertinoTextField.borderless(
                  controller: controller,
                  placeholder: placeholder,
                  keyboardType: keyboardType,
                  obscureText: obscureText,
                  autofocus: autofocus,
                  autocorrect: false,
                  textAlign: TextAlign.right,
                  padding: EdgeInsets.zero,
                  onChanged: onChanged,
                  style: const TextStyle(fontSize: 17, color: AppColors.label),
                  placeholderStyle: const TextStyle(
                    fontSize: 17,
                    color: AppColors.label3,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppMetrics.gutter, 0, AppMetrics.gutter, 8),
            child: Text(
              errorText!,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, color: AppColors.red),
            ),
          ),
      ],
    );
  }
}

/// A row whose value cannot be edited — used for the inspector, which is derived
/// from the session and must never be assignable (RLS owns that rule).
class ReadOnlyRow extends StatelessWidget {
  const ReadOnlyRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 100,
    this.valueKey,
  });

  final String label;
  final String value;
  final double labelWidth;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppMetrics.rowHeight),
      padding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(fontSize: 17, color: AppColors.label),
            ),
          ),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 17, color: AppColors.label2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width filled action, 52pt tall with a 14pt radius.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: AppMetrics.buttonHeight,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        color: AppColors.blue,
        borderRadius: BorderRadius.circular(AppMetrics.buttonRadius),
        onPressed: busy ? null : onPressed,
        child: busy
            ? const CupertinoActivityIndicator(color: AppColors.card)
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: AppColors.card,
                ),
              ),
      ),
    );
  }
}

/// Severity colours.
///
/// The Figma mockup has three severities (`minor | major | critical`); the
/// accepted schema has four. Rather than migrate the database to match a
/// picture (D14), the mockup's own iOS palette is stretched across the four
/// values as a natural ramp: green -> yellow -> orange -> red.
///
/// Tints are precomputed ARGB constants because `withOpacity` is deprecated on
/// newer SDKs and `withValues` does not exist on older ones.
class SeverityPalette {
  const SeverityPalette._();

  static Color foreground(ItemSeverity s) => switch (s) {
        ItemSeverity.low => AppColors.green,
        ItemSeverity.medium => const Color(0xFFB58900),
        ItemSeverity.high => const Color(0xFFFF9500),
        ItemSeverity.critical => AppColors.red,
      };

  /// ~15% of the foreground, for the chip background.
  static Color tint(ItemSeverity s) => switch (s) {
        ItemSeverity.low => const Color(0x2634C759),
        ItemSeverity.medium => const Color(0x26FFCC00),
        ItemSeverity.high => const Color(0x26FF9500),
        ItemSeverity.critical => const Color(0x26FF3B30),
      };
}

/// A severity chip: colour plus the word, never colour alone. Severity is the
/// field a reader acts on, and colour by itself excludes anyone who cannot
/// distinguish these hues.
class SeverityChip extends StatelessWidget {
  const SeverityChip({super.key, required this.severity});

  final ItemSeverity severity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SeverityPalette.tint(severity),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        severity.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: SeverityPalette.foreground(severity),
        ),
      ),
    );
  }
}
