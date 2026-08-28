import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/models/diagnosis_result.dart';
import '../../../core/services/ai_reliability_engine.dart';
import '../../../core/services/remedy_service.dart';
import '../../../core/services/tflite_service.dart';
import '../../../core/services/voice_assistant_service.dart';
import '../../../core/utils/image_checker.dart';
import '../../escalation/escalation_service.dart';
import '../../escalation/expert_queue_screen.dart';
import '../../passport/passport_service.dart';
import '../widgets/heatmap_overlay_widget.dart';
import '../widgets/severity_calculator.dart';
import '../widgets/severity_gauge.dart';
import '../widgets/why_this_diagnosis_card.dart';

/// Everything the results UI needs, produced by the diagnosis pipeline.
class DiagnosisPipelineOutput {
  const DiagnosisPipelineOutput({
    required this.result,
    this.severity,
    this.frameQuality,
    this.remedy,
  });

  final DiagnosisResult result;
  final SeverityResult? severity;
  final FrameQualityResult? frameQuality;
  final Remedy? remedy;
}

/// Renders the diagnosis for a captured image: full remedy view on high
/// confidence, escalation card on low confidence, rejection card on OOD.
class DiagnosisResultScreen extends StatefulWidget {
  const DiagnosisResultScreen({
    super.key,
    required this.imagePath,
    this.precomputed,
  });

  final String imagePath;

  /// Injectable pipeline output for tests; when null the screen runs the
  /// quality-check -> inference -> severity pipeline itself.
  final DiagnosisPipelineOutput? precomputed;

  @override
  State<DiagnosisResultScreen> createState() => _DiagnosisResultScreenState();
}

class _DiagnosisResultScreenState extends State<DiagnosisResultScreen> {
  static const _engine = AIReliabilityEngine();

  late final Future<DiagnosisPipelineOutput> _pipeline;
  final VoiceAssistantService _voice = VoiceAssistantService.instance;

  /// 'en' or 'hi' — controls both displayed remedy text and TTS.
  String _lang = 'hi';
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    _pipeline = widget.precomputed != null
        ? Future.value(widget.precomputed)
        : _runPipeline();
  }

  @override
  void dispose() {
    _voice.stop();
    super.dispose();
  }

  Future<DiagnosisPipelineOutput> _runPipeline() async {
    final quality = await File(widget.imagePath).validateForInference();
    final result = await _engine.diagnoseFile(
      widget.imagePath,
      tflite: TFLiteService.instance,
      frameQuality: quality,
    );

    SeverityResult? severity;
    if (!result.isOOD) {
      severity = await SeverityCalculator.analyzeFile(widget.imagePath);
    }

    Remedy? remedy;
    try {
      await RemedyService.instance.load();
      remedy = RemedyService.instance.forKey(result.remedyKey);
    } catch (e) {
      debugPrint('DiagnosisResultScreen: remedies unavailable ($e)');
    }

    // Storage side effects — never allowed to break the diagnosis UI.
    try {
      if (result.reliabilityState == ReliabilityState.highConfidence) {
        await CropHealthPassportService.instance
            .recordScan(result: result, severity: severity);
        if (severity?.category == SeverityCategory.severe) {
          // Severe cases go to the expert queue automatically.
          await ExpertEscalationService.instance.enqueue(result);
        }
      }
    } catch (e) {
      debugPrint('DiagnosisResultScreen: local storage failed ($e)');
    }

    return DiagnosisPipelineOutput(
      result: result,
      severity: severity,
      frameQuality: quality,
      remedy: remedy,
    );
  }

  Future<void> _saveToExpertQueue(DiagnosisResult result) async {
    await ExpertEscalationService.instance.enqueue(result);
    if (!mounted) return;
    setState(() => _queued = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved to Expert Queue — शेयर के लिए सहेजा गया'),
      ),
    );
  }

  String _speechFor(DiagnosisPipelineOutput data) {
    final hi = _lang == 'hi';
    switch (data.result.reliabilityState) {
      case ReliabilityState.highConfidence:
        final remedy = data.remedy;
        if (remedy != null) {
          final severityLine = data.severity == null
              ? ''
              : hi
                  ? 'गंभीरता: ${data.severity!.category.labelHi}, '
                      '${data.severity!.percentLabel} पत्ती प्रभावित। '
                  : 'Severity: ${data.severity!.category.labelEn}, '
                      '${data.severity!.percentLabel} of the leaf affected. ';
          return severityLine + remedy.speechText(_lang);
        }
        return hi ? 'निदान तैयार है।' : 'Diagnosis ready.';
      case ReliabilityState.lowConfidenceEscalate:
        return hi
            ? 'जांच अनिर्णीत रही। पर्याप्त प्रमाण नहीं मिले। यह स्कैन विशेषज्ञ '
                'समीक्षा के लिए भेजा जा सकता है।'
            : 'The scan was inconclusive. There was not enough evidence. '
                'You can queue this scan for expert review.';
      case ReliabilityState.outOfBoundsReject:
        return hi
            ? 'कोई मान्य पत्ती नहीं मिली। कृपया कैमरा फसल की पत्ती की ओर करें।'
            : 'No valid leaf detected. Please point the camera at a crop '
                'leaf.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnosis Result'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<String>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(value: 'hi', label: Text('हिंदी')),
                ButtonSegment(value: 'en', label: Text('EN')),
              ],
              selected: {_lang},
              onSelectionChanged: (selection) {
                _voice.stop();
                setState(() => _lang = selection.first);
              },
            ),
          ),
        ],
      ),
      body: FutureBuilder<DiagnosisPipelineOutput>(
        future: _pipeline,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorBody(error: '${snapshot.error}');
          }
          if (!snapshot.hasData) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text('Validating Frame & Running Edge Model...'),
                ],
              ),
            );
          }
          return _buildResult(snapshot.data!);
        },
      ),
      floatingActionButton: FutureBuilder<DiagnosisPipelineOutput>(
        future: _pipeline,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          return _VoiceControls(
            voice: _voice,
            lang: _lang,
            onPlay: () => _voice.speak(_speechFor(snapshot.data!), _lang),
          );
        },
      ),
    );
  }

  Widget _buildResult(DiagnosisPipelineOutput data) {
    switch (data.result.reliabilityState) {
      case ReliabilityState.outOfBoundsReject:
        return _AlertBody(
          color: AppColors.severitySevere,
          icon: Icons.no_photography,
          badge: 'INVALID PHOTO',
          title: 'No Valid Leaf Detected',
          message:
              'No leaf found. Please point the camera at a crop leaf.\n'
              'कृपया कैमरा फसल की पत्ती की ओर करें।',
          actionIcon: Icons.camera_alt,
          actionLabel: 'Scan Again',
          onAction: () => Navigator.of(context).pop(),
        );
      case ReliabilityState.lowConfidenceEscalate:
        final pct =
            (data.result.confidenceScore * 100).toStringAsFixed(0);
        return _AlertBody(
          color: AppColors.severityModerate,
          icon: _queued ? Icons.cloud_done : Icons.cloud_upload,
          badge: _queued ? 'SCAN QUEUED OFFLINE' : 'NEEDS EXPERT REVIEW',
          title: 'Inconclusive Scan',
          message:
              'Confidence $pct% — below the '
              '${(AIReliabilityEngine.highConfidenceThreshold * 100).round()}% '
              'reliability threshold. Insufficient evidence for a diagnosis.\n'
              'Queued scans are reviewed by an agriculture expert.',
          actionIcon: _queued ? Icons.check : Icons.support_agent,
          actionLabel:
              _queued ? 'Saved to Expert Queue ✓' : 'Save to Expert Queue',
          onAction: _queued ? null : () => _saveToExpertQueue(data.result),
          secondaryLabel: _queued ? 'View Expert Queue' : 'Scan Again',
          onSecondary: _queued
              ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ExpertQueueScreen(),
                    ),
                  )
              : () => Navigator.of(context).pop(),
        );
      case ReliabilityState.highConfidence:
        return _HighConfidenceBody(
          data: data,
          lang: _lang,
          imagePath: widget.imagePath,
        );
    }
  }
}

/// Floating speaker controls: a large extended FAB with a language badge
/// and a pulsing ring while audio plays (so judges can see TTS is live),
/// plus a pause/resume mini button when active.
class _VoiceControls extends StatefulWidget {
  const _VoiceControls({
    required this.voice,
    required this.lang,
    required this.onPlay,
  });

  final VoiceAssistantService voice;
  final String lang;
  final VoidCallback onPlay;

  @override
  State<_VoiceControls> createState() => _VoiceControlsState();
}

class _VoiceControlsState extends State<_VoiceControls>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hindi = widget.lang == 'hi';
    return ValueListenableBuilder<TtsPlaybackState>(
      valueListenable: widget.voice.state,
      builder: (context, state, _) {
        final playing = state == TtsPlaybackState.playing;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (state != TtsPlaybackState.stopped) ...[
              FloatingActionButton.small(
                heroTag: 'tts_pause',
                onPressed: playing ? widget.voice.pause : widget.voice.resume,
                child: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(height: 12),
            ],
            Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Pulsing sound-wave ring, visible only while speaking.
                if (playing)
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) {
                      final t = _pulse.value;
                      return Positioned.fill(
                        child: Center(
                          child: Container(
                            width: 130 + 44 * t,
                            height: 58 + 30 * t,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(48),
                              border: Border.all(
                                color: AppColors.emerald
                                    .withValues(alpha: 0.6 * (1 - t)),
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                FloatingActionButton.extended(
                  heroTag: 'tts_main',
                  backgroundColor:
                      playing ? AppColors.emerald : AppColors.forestGreen,
                  foregroundColor: Colors.white,
                  elevation: 6,
                  onPressed: state == TtsPlaybackState.stopped
                      ? widget.onPlay
                      : widget.voice.stop,
                  icon: Icon(
                    state == TtsPlaybackState.stopped
                        ? Icons.volume_up
                        : Icons.stop,
                    size: 30,
                  ),
                  label: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playing
                            ? (hindi ? 'बोल रहा है...' : 'Speaking...')
                            : (hindi ? 'सुनें' : 'Listen'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        hindi ? 'Hindi Audio' : 'English Audio',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// High-impact full-screen state card (OOD rejection / expert escalation):
/// pulsing halo icon, shouty status badge, and large primary action.
class _AlertBody extends StatefulWidget {
  const _AlertBody({
    required this.color,
    required this.icon,
    required this.badge,
    required this.title,
    required this.message,
    required this.actionIcon,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final Color color;
  final IconData icon;
  final String badge;
  final String title;
  final String message;
  final IconData actionIcon;
  final String actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  State<_AlertBody> createState() => _AlertBodyState();
}

class _AlertBodyState extends State<_AlertBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Card(
          color: AppColors.statusTint(color),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: color.withValues(alpha: 0.5), width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated icon inside a breathing halo.
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) {
                    final t = _pulse.value;
                    return Container(
                      width: 116,
                      height: 116,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withValues(alpha: 0.10 + 0.08 * t),
                        border: Border.all(
                          color: color.withValues(alpha: 0.35 + 0.4 * t),
                          width: 2.5,
                        ),
                      ),
                      child: Transform.scale(
                        scale: 0.94 + 0.09 * t,
                        child: Icon(widget.icon, size: 58, color: color),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),
                // Status badge banner.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    widget.badge,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(color: color),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: widget.onAction,
                  style: FilledButton.styleFrom(backgroundColor: color),
                  icon: Icon(widget.actionIcon),
                  label: Text(widget.actionLabel),
                ),
                if (widget.secondaryLabel != null) ...[
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: widget.onSecondary,
                    child: Text(
                      widget.secondaryLabel!,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HighConfidenceBody extends StatelessWidget {
  const _HighConfidenceBody({
    required this.data,
    required this.lang,
    required this.imagePath,
  });

  final DiagnosisPipelineOutput data;
  final String lang;
  final String imagePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = data.result;
    final severity = data.severity;
    final remedy = data.remedy;
    final isDisease = remedy?.type == 'disease';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        GradCAMHeatmapOverlay(
          imagePath: imagePath,
          diseaseClass: result.className,
          severity: severity,
        ),
        const SizedBox(height: 16),

        // Disease name + confidence.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  remedy?.displayName(lang) ?? result.className,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isDisease
                        ? AppColors.severitySevere
                        : AppColors.severityHealthy,
                  ),
                ),
                if (remedy != null)
                  Text(
                    remedy.displayName(lang == 'hi' ? 'en' : 'hi'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Chip(
                      avatar: const Icon(Icons.verified, size: 18),
                      label: Text(
                        '${(result.confidenceScore * 100).toStringAsFixed(0)}% '
                        'confidence',
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (result.usedMockModel)
                      const Chip(
                        avatar: Icon(Icons.science, size: 18),
                        label: Text('Demo model'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Radial severity gauge + tissue breakdown.
        if (severity != null && isDisease) ...[
          const SizedBox(height: 8),
          SeverityGauge(severity: severity, lang: lang),
        ],

        // Explainability accordion.
        if (severity != null) ...[
          const SizedBox(height: 8),
          WhyThisDiagnosisCard(
            result: result,
            severity: severity,
            frameQuality: data.frameQuality,
          ),
        ],

        // Remedies.
        if (remedy != null) ...[
          if (isDisease) ...[
            _RemedySection(
              icon: Icons.search,
              title: lang == 'hi' ? 'लक्षण' : 'Symptoms',
              body: remedy.text('symptoms', lang),
            ),
            _RemedySection(
              icon: Icons.eco,
              title: lang == 'hi' ? 'जैविक उपचार' : 'Organic Treatment',
              steps: remedy.list('organic_treatment', lang),
              color: AppColors.severityHealthy,
            ),
            _RemedySection(
              icon: Icons.science,
              title: lang == 'hi' ? 'रासायनिक उपचार' : 'Chemical Treatment',
              steps: remedy.list('chemical_treatment', lang),
              color: AppColors.severityModerate,
            ),
            _RemedySection(
              icon: Icons.shield,
              title: lang == 'hi' ? 'रोकथाम' : 'Prevention',
              steps: remedy.list('prevention', lang),
            ),
          ] else
            _RemedySection(
              icon: Icons.tips_and_updates,
              title: lang == 'hi' ? 'सलाह' : 'Advice',
              steps: remedy.list('advice', lang),
              color: AppColors.severityHealthy,
            ),
          if (remedy.text('escalation_advice', lang).isNotEmpty)
            _RemedySection(
              icon: Icons.support_agent,
              title: lang == 'hi' ? 'विशेषज्ञ से कब संपर्क करें' : 'When to Escalate',
              body: remedy.text('escalation_advice', lang),
            ),
        ],
      ],
    );
  }
}

class _RemedySection extends StatelessWidget {
  const _RemedySection({
    required this.icon,
    required this.title,
    this.body,
    this.steps = const [],
    this.color,
  });

  final IconData icon;
  final String title;
  final String? body;
  final List<String> steps;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if ((body == null || body!.isEmpty) && steps.isEmpty) {
      return const SizedBox.shrink();
    }
    final accent = color ?? theme.colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (body != null && body!.isNotEmpty)
              Text(body!, style: theme.textTheme.bodyMedium),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 2, right: 8),
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        steps[i],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text('Diagnosis failed: $error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to Scanner'),
            ),
          ],
        ),
      ),
    );
  }
}
