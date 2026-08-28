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

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

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
    );

    return MaterialApp(
      title: 'CropCureAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: baseScheme,
        scaffoldBackgroundColor: baseScheme.surface,
        textTheme: GoogleFonts.interTextTheme(),
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.forestGreen,
          foregroundColor: Colors.white,
          centerTitle: true,
          titleTextStyle: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          indicatorColor: AppColors.forestGreen.withValues(alpha: 0.15),
        ),
      ),
      home: const AppShell(),
    );
  }
}
