import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_shell.dart';
import 'core/constants/app_colors.dart';
import 'core/services/tflite_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Offline guarantee: never fetch fonts at runtime. Without bundled font
  // files google_fonts falls back to the platform default typeface.
  GoogleFonts.config.allowRuntimeFetching = false;

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Warm up the interpreter (or flip to mock mode) before the first scan.
  // Fire-and-forget: the service is idempotent and re-awaited on use.
  TFLiteService.instance.load();

  runApp(const CropCureApp());
}

class CropCureApp extends StatelessWidget {
  const CropCureApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: AppColors.forestGreen,
      primary: AppColors.forestGreen,
      secondary: AppColors.emerald,
      surface: AppColors.warmCream,
    );

    // High-legibility type scale: Plus Jakarta Sans, generous sizes and
    // weights so remedy steps stay readable at arm's length / on a
    // mirrored projector.
    final textTheme = GoogleFonts.plusJakartaSansTextTheme().copyWith(
      headlineMedium: GoogleFonts.plusJakartaSans(
        fontSize: 30,
        fontWeight: FontWeight.w800,
      ),
      titleLarge: GoogleFonts.plusJakartaSans(
        fontSize: 23,
        fontWeight: FontWeight.w800,
      ),
      titleMedium: GoogleFonts.plusJakartaSans(
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      titleSmall: GoogleFonts.plusJakartaSans(
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
      bodyLarge: GoogleFonts.plusJakartaSans(fontSize: 17, height: 1.45),
      bodyMedium: GoogleFonts.plusJakartaSans(fontSize: 15.5, height: 1.45),
      bodySmall: GoogleFonts.plusJakartaSans(fontSize: 13, height: 1.35),
      labelLarge: GoogleFonts.plusJakartaSans(
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    );

    return MaterialApp(
      title: 'CropCureAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: baseScheme,
        scaffoldBackgroundColor: AppColors.warmCream,
        textTheme: textTheme,
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.forestGreen,
          foregroundColor: Colors.white,
          centerTitle: true,
          titleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(58),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            side: const BorderSide(color: AppColors.emerald, width: 1.6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.06)),
          ),
        ),
        chipTheme: ChipThemeData(
          labelStyle: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          side: BorderSide.none,
          backgroundColor: AppColors.forestGreen.withValues(alpha: 0.10),
        ),
        navigationBarTheme: NavigationBarThemeData(
          height: 74,
          backgroundColor: Colors.white,
          indicatorColor: AppColors.forestGreen.withValues(alpha: 0.14),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 28,
              color: states.contains(WidgetState.selected)
                  ? AppColors.forestGreen
                  : AppColors.severityUnknown,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => GoogleFonts.plusJakartaSans(
              fontSize: 12.5,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? AppColors.forestGreen
                  : AppColors.severityUnknown,
            ),
          ),
        ),
      ),
      home: const AppShell(),
    );
  }
}
