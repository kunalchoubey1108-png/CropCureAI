import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_colors.dart';
import '../../core/utils/image_checker.dart';
import '../../widgets/common.dart';
import 'camera_overlay_widget.dart';

/// Live camera scanner with a leaf bounding-box overlay, frame quality
/// validation, and a gallery fallback for demo conditions where the
/// room lighting is too poor for a live capture.
class SmartScannerScreen extends StatefulWidget {
  const SmartScannerScreen({
    super.key,
    required this.onImageReady,
    this.topBarTrailing,
  });

  /// Receives the validated image path for the diagnosis step.
  final void Function(BuildContext context, String imagePath) onImageReady;

  /// Optional action shown at the right end of the top bar (demo panel).
  final Widget? topBarTrailing;

  @override
  State<SmartScannerScreen> createState() => _SmartScannerScreenState();
}

class _SmartScannerScreenState extends State<SmartScannerScreen>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();

  CameraController? _controller;
  String? _cameraError;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when backgrounded; re-acquire on return.
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      // Timeout guards against a wedged camera stack (or test environments
      // where the platform channel never answers): fall back to gallery.
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 5),
      );
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'No camera found on this device.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraError = null;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraError = e.code == 'CameraAccessDenied'
            ? 'Camera permission denied. You can still pick a photo from the gallery.'
            : 'Camera unavailable (${e.code}). Use the gallery instead.';
      });
    } catch (e) {
      // Any other failure (missing plugin, emulator quirks): degrade to
      // the gallery fallback instead of crashing the demo.
      if (!mounted) return;
      setState(
        () => _cameraError = 'Camera unavailable. Use the gallery instead.',
      );
    }
  }

  Future<void> _captureFromCamera() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _processing) {
      return;
    }
    try {
      final shot = await controller.takePicture();
      await _validateAndProceed(shot.path, fromGallery: false);
    } on CameraException catch (e) {
      _showMessage('Capture failed (${e.code}). Try again or use the gallery.');
    }
  }

  /// Hackathon safeguard: lets us demo with sample images when the venue
  /// lighting is too poor for a live capture.
  Future<void> _pickFromGallery() async {
    if (_processing) return;
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
    );
    if (picked == null || !mounted) return;
    await _validateAndProceed(picked.path, fromGallery: true);
  }

  Future<void> _validateAndProceed(
    String path, {
    required bool fromGallery,
  }) async {
    setState(() => _processing = true);
    final FrameQualityResult quality;
    try {
      quality = await File(path).validateForInference();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
    if (!mounted) return;

    if (!quality.isUsable) {
      if (fromGallery) {
        // Gallery samples proceed anyway (that is the whole point of the
        // fallback), but we still surface the warning.
        _showMessage('Note: ${quality.issues.first}');
      } else {
        _showMessage(quality.issues.first);
        return; // Stay on the scanner for a retake.
      }
    }

    widget.onImageReady(context, path);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraLayer(),
          if (_cameraError == null) const CameraOverlayWidget(),
          _buildTopBar(),
          _buildBottomControls(),
          if (_processing) _buildProcessingOverlay(),
        ],
      ),
    );
  }

  Widget _buildCameraLayer() {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.no_photography, color: Colors.white38, size: 64),
              const SizedBox(height: 16),
              Text(
                _cameraError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick from gallery'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    // Fill the screen, cropping instead of letterboxing.
    final preview = controller.value.previewSize!;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        // previewSize is landscape-oriented; swap for portrait UI.
        width: preview.height,
        height: preview.width,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _buildTopBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: GestureDetector(
        // Hidden shortcut: long-press the top bar to open the gallery.
        onLongPress: _pickFromGallery,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const Expanded(
                  child: Text(
                    'Smart Scanner',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Balances the back button when no action is provided.
                widget.topBarTrailing ?? const SizedBox(width: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final cameraReady =
        _cameraError == null && (_controller?.value.isInitialized ?? false);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Gallery fallback in the bottom corner: large, labeled.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.6),
                          width: 1.5,
                        ),
                      ),
                      child: IconButton(
                        onPressed: _pickFromGallery,
                        iconSize: 30,
                        tooltip: 'Pick from gallery',
                        icon: const Icon(
                          Icons.photo_library,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Gallery',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                // Tactile shutter with an animated outer ripple ring.
                _RippleShutterButton(
                  enabled: cameraReady,
                  onTap: _captureFromCamera,
                ),
                // Spacer matching the gallery column, keeps shutter centered.
                const SizedBox(width: 62, height: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.7),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text(
              'Validating Frame & Running Edge Model...',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// Large circular capture button with a continuously expanding ripple
/// ring so it reads as "alive" and tappable from across a demo room.
class _RippleShutterButton extends StatelessWidget {
  const _RippleShutterButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 108,
        height: 108,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (enabled)
              PulseBuilder(
                duration: const Duration(milliseconds: 1600),
                builder: (context, t) => Container(
                  width: 80 + 28 * t,
                  height: 80 + 28 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.7 * (1 - t)),
                      width: 3,
                    ),
                  ),
                ),
              ),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 5),
                color: enabled ? AppColors.emerald : Colors.white24,
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: AppColors.emerald.withValues(alpha: 0.55),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: const Icon(
                Icons.energy_savings_leaf,
                color: Colors.white,
                size: 36,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
