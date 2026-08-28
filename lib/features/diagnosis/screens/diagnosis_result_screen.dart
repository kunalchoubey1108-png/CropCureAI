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
import '../../passport/passport_service.dart';
import '../widgets/heatmap_overlay_widget.dart';
import '../widgets/severity_calculator.dart';
import '../widgets/why_this_diagnosis_dialog.dart';

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
          icon: Icons.error_outline,
          title: 'No Valid Leaf Detected',
          message:
              'Please point the camera at a crop leaf.\nकृपया कैमरा फसल की '
              'पत्ती की ओर करें।',
          actionLabel: 'Scan Again',
          onAction: () => Navigator.of(context).pop(),
        );
      case ReliabilityState.lowConfidenceEscalate:
        final pct =
            (data.result.confidenceScore * 100).toStringAsFixed(0);
        return _AlertBody(
          color: AppColors.severityModerate,
          icon: Icons.help_outline,
          title: 'Inconclusive Scan',
          message:
              'Confidence $pct% — below the '
              '${(AIReliabilityEngine.highConfidenceThreshold * 100).round()}% '
              'reliability threshold. Insufficient evidence for a diagnosis.\n'
              'Queued scans are reviewed by an agriculture expert.',
          actionLabel: _queued ? 'Saved to Expert Queue ✓' : 'Save to Expert Queue',
          onAction: _queued ? null : () => _saveToExpertQueue(data.result),
          secondaryLabel: 'Scan Again',
          onSecondary: () => Navigator.of(context).pop(),
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

/// Floating speaker controls: play/stop plus a pause/resume mini button
/// while audio is active.
class _VoiceControls extends StatelessWidget {
  const _VoiceControls({required this.voice, required this.onPlay});

  final VoiceAssistantService voice;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsPlaybackState>(
      valueListenable: voice.state,
      builder: (context, state, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (state != TtsPlaybackState.stopped) ...[
              FloatingActionButton.small(
                heroTag: 'tts_pause',
                onPressed: state == TtsPlaybackState.playing
                    ? voice.pause
                    : voice.resume,
                child: Icon(
                  state == TtsPlaybackState.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
              ),
              const SizedBox(height: 12),
            ],
            FloatingActionButton(
              heroTag: 'tts_main',
              onPressed:
                  state == TtsPlaybackState.stopped ? onPlay : voice.stop,
              child: Icon(
                state == TtsPlaybackState.stopped
                    ? Icons.volume_up
                    : Icons.stop,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AlertBody extends StatelessWidget {
  const _AlertBody({
    required this.color,
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          color: color.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: color.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 64, color: color),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(backgroundColor: color),
                  child: Text(actionLabel),
                ),
                if (secondaryLabel != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
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

  Color get _severityColor => switch (data.severity?.category) {
        SeverityCategory.severe => AppColors.severitySevere,
        SeverityCategory.moderate => AppColors.severityModerate,
        SeverityCategory.mild || null => AppColors.severityHealthy,
      };

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

        // Severity progress bar.
        if (severity != null && isDisease) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Severity',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${lang == 'hi' ? severity.category.labelHi : severity.category.labelEn}'
                        ' — ${severity.percentLabel}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: _severityColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: (severity.infectionPercent / 100).clamp(0.0, 1.0),
                      minHeight: 12,
                      color: _severityColor,
                      backgroundColor:
                          _severityColor.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        // Explainability.
        if (severity != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => WhyThisDiagnosisDialog.show(
              context,
              result: result,
              severity: severity,
              frameQuality: data.frameQuality,
            ),
            icon: const Icon(Icons.psychology),
            label: const Text('Why This Diagnosis?'),
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
