import 'package:flutter/material.dart';

/// Central color palette for CropCureAI.
abstract final class AppColors {
  /// Primary brand color — Forest Green.
  static const Color forestGreen = Color(0xFF1B5E20);

  /// Severity indicators used on diagnosis cards.
  static const Color severityHealthy = Color(0xFF2E7D32);
  static const Color severityModerate = Color(0xFFF9A825);
  static const Color severitySevere = Color(0xFFC62828);
  static const Color severityUnknown = Color(0xFF616161);
}
