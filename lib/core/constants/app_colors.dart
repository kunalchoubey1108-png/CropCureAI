import 'package:flutter/material.dart';

/// Central color palette for CropCureAI.
///
/// High-contrast, status-driven system tuned for low-literacy users and
/// screen-mirrored demos: every state has one unambiguous color.
abstract final class AppColors {
  /// Primary brand color — Deep Forest Green.
  static const Color forestGreen = Color(0xFF1B5E20);

  /// Secondary brand green — Emerald.
  static const Color emerald = Color(0xFF2E7D32);

  /// App background — Warm Cream.
  static const Color warmCream = Color(0xFFFAFAFA);

  // ---- Status / severity system -------------------------------------
  // Green  -> valid scan / high confidence / improving
  // Amber  -> inconclusive / low confidence / moderate severity
  // Crimson-> OOD rejection / high severity / worsening

  static const Color severityHealthy = Color(0xFF2E7D32);
  static const Color severityModerate = Color(0xFFF57C00);
  static const Color severitySevere = Color(0xFFC62828);
  static const Color severityUnknown = Color(0xFF616161);

  /// Soft tinted backgrounds for status surfaces.
  static Color statusTint(Color status) => status.withValues(alpha: 0.10);

  /// Scanner accent (brackets, laser line).
  static const Color scannerAccent = Color(0xFF9CFF57);
}
