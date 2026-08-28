import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import 'passport_service.dart';

/// Historical timeline of leaf scans with a mini recovery-trend chart.
class CropHealthPassportScreen extends StatefulWidget {
  const CropHealthPassportScreen({super.key, this.extraActions = const []});

  /// Extra app-bar actions injected by the shell (demo panel button).
  final List<Widget> extraActions;

  @override
  State<CropHealthPassportScreen> createState() =>
      _CropHealthPassportScreenState();
}

class _CropHealthPassportScreenState extends State<CropHealthPassportScreen> {
  late Future<List<PassportEntry>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _entriesFuture = CropHealthPassportService.instance.entries();
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear passport?'),
        content: const Text(
          'This deletes the whole scan history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await CropHealthPassportService.instance.clear();
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop Health Passport'),
        actions: [
          ...widget.extraActions,
          IconButton(
            tooltip: 'Clear history',
            onPressed: _confirmClear,
            icon: const Icon(Icons.delete_sweep),
          ),
        ],
      ),
      body: FutureBuilder<List<PassportEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const _EmptyState();
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _RecoveryChartCard(entries: entries),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Scan Timeline',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              for (final entry in entries)
                _TimelineTile(
                  entry: entry,
                  onDelete: () async {
                    await CropHealthPassportService.instance.delete(entry.id);
                    if (mounted) setState(_reload);
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book,
              size: 72,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No scans yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Diagnosed scans are saved here automatically so you can '
              'track your crop\'s recovery over time.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Severity-over-time line chart for the most recently scanned crop.
class _RecoveryChartCard extends StatelessWidget {
  const _RecoveryChartCard({required this.entries});

  final List<PassportEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Chart the crop from the latest scan, oldest -> newest, last 7 scans.
    final crop = entries.first.cropType;
    final series = entries
        .where((e) => e.cropType == crop)
        .toList()
        .reversed
        .toList();
    final points = series.length > 7
        ? series.sublist(series.length - 7)
        : series;

    if (points.length < 2) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.show_chart, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Scan the same crop again in a few days to see its '
                  'recovery trend here.',
                ),
              ),
            ],
          ),
        ),
      );
    }

    final firstDay = points.first.timestamp;
    int dayOf(PassportEntry e) =>
        e.timestamp.difference(firstDay).inDays + 1;
    final first = points.first;
    final last = points.last;
    final recovering =
        last.severityPercentage < first.severityPercentage - 0.5;
    final trendColor =
        recovering ? AppColors.severityHealthy : AppColors.severitySevere;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  recovering ? Icons.trending_down : Icons.trending_up,
                  color: trendColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$crop Recovery Trend',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _PulsingStatusBadge(
                  label: recovering ? 'Status: Improving' : 'Status: Watch',
                  color: trendColor,
                  pulsing: recovering,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Day ${dayOf(first)}: '
              '${first.severityPercentage.toStringAsFixed(0)}% severity'
              '  →  Day ${dayOf(last)}: '
              '${last.severityPercentage.toStringAsFixed(0)}% severity',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            // Side-by-side first vs latest scan comparison.
            Row(
              children: [
                Expanded(
                  child: _ComparisonThumb(
                    entry: first,
                    caption: 'Day ${dayOf(first)}',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.arrow_forward, color: trendColor),
                ),
                Expanded(
                  child: _ComparisonThumb(
                    entry: last,
                    caption: 'Day ${dayOf(last)}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: CustomPaint(
                size: const Size(double.infinity, 140),
                painter: _RecoveryChartPainter(
                  days: [for (final p in points) dayOf(p)],
                  severities: [
                    for (final p in points) p.severityPercentage,
                  ],
                  lineColor: theme.colorScheme.primary,
                  labelColor: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small pulsing status pill ("Status: Improving").
class _PulsingStatusBadge extends StatefulWidget {
  const _PulsingStatusBadge({
    required this.label,
    required this.color,
    required this.pulsing,
  });

  final String label;
  final Color color;
  final bool pulsing;

  @override
  State<_PulsingStatusBadge> createState() => _PulsingStatusBadgeState();
}

class _PulsingStatusBadgeState extends State<_PulsingStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.pulsing) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        widget.label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    if (!widget.pulsing) return badge;
    return FadeTransition(
      opacity: Tween(begin: 0.7, end: 1.0).animate(_pulse),
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.03).animate(_pulse),
        child: badge,
      ),
    );
  }
}

/// Thumbnail + severity caption used in the Day-vs-Day comparison row.
class _ComparisonThumb extends StatelessWidget {
  const _ComparisonThumb({required this.entry, required this.caption});

  final PassportEntry entry;
  final String caption;

  Color get _severityColor => entry.severityPercentage > 30
      ? AppColors.severitySevere
      : entry.severityPercentage >= 10
          ? AppColors.severityModerate
          : AppColors.severityHealthy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: entry.imagePath.isEmpty
                ? const ColoredBox(
                    color: Colors.black12,
                    child: Icon(Icons.eco, size: 32),
                  )
                : Image.file(
                    File(entry.imagePath),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.eco, size: 32),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: theme.textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: _severityColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${entry.severityPercentage.toStringAsFixed(0)}% infected',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: _severityColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _RecoveryChartPainter extends CustomPainter {
  const _RecoveryChartPainter({
    required this.days,
    required this.severities,
    required this.lineColor,
    required this.labelColor,
  });

  final List<int> days;
  final List<double> severities;
  final Color lineColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 8.0;
    const rightPad = 8.0;
    const topPad = 16.0;
    const bottomPad = 24.0;
    final plotW = size.width - leftPad - rightPad;
    final plotH = size.height - topPad - bottomPad;

    final maxSeverity = max(30.0, severities.reduce(max) * 1.15);
    final minDay = days.first;
    final daySpan = max(1, days.last - minDay);

    Offset pointAt(int i) => Offset(
          leftPad + plotW * (days[i] - minDay) / daySpan,
          topPad + plotH * (1 - severities[i] / maxSeverity),
        );

    // Faint horizontal gridlines.
    final grid = Paint()
      ..color = labelColor.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (var g = 0; g <= 2; g++) {
      final y = topPad + plotH * g / 2;
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + plotW, y), grid);
    }

    // Severity polyline with soft fill underneath.
    final line = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < days.length; i++) {
      line.lineTo(pointAt(i).dx, pointAt(i).dy);
    }
    final fill = Path.from(line)
      ..lineTo(pointAt(days.length - 1).dx, topPad + plotH)
      ..lineTo(pointAt(0).dx, topPad + plotH)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = lineColor.withValues(alpha: 0.10),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // Dots + labels.
    for (var i = 0; i < days.length; i++) {
      final p = pointAt(i);
      final severity = severities[i];
      final dotColor = severity > 30
          ? AppColors.severitySevere
          : severity >= 10
              ? AppColors.severityModerate
              : AppColors.severityHealthy;
      canvas.drawCircle(p, 5, Paint()..color = dotColor);
      canvas.drawCircle(
        p,
        5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      _drawLabel(
        canvas,
        '${severity.toStringAsFixed(0)}%',
        Offset(p.dx, p.dy - 16),
        labelColor,
        bold: true,
      );
      _drawLabel(
        canvas,
        'Day ${days[i]}',
        Offset(p.dx, topPad + plotH + 12),
        labelColor,
      );
    }
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset center,
    Color color, {
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_RecoveryChartPainter oldDelegate) =>
      oldDelegate.days != days || oldDelegate.severities != severities;
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.entry, required this.onDelete});

  final PassportEntry entry;
  final VoidCallback onDelete;

  Color get _statusColor => switch (entry.status) {
        ScanTrendStatus.improving => AppColors.severityHealthy,
        ScanTrendStatus.stable => AppColors.severityUnknown,
        ScanTrendStatus.worsening => AppColors.severitySevere,
      };

  IconData get _statusIcon => switch (entry.status) {
        ScanTrendStatus.improving => Icons.trending_down,
        ScanTrendStatus.stable => Icons.trending_flat,
        ScanTrendStatus.worsening => Icons.trending_up,
      };

  static String _formatDate(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ampm = t.hour < 12 ? 'am' : 'pm';
    return '${t.day} ${months[t.month - 1]} ${t.year}, '
        '$h:${t.minute.toString().padLeft(2, '0')} $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: AppColors.severitySevere,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 52,
              height: 52,
              child: entry.imagePath.isEmpty
                  ? const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.eco),
                    )
                  : Image.file(
                      File(entry.imagePath),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) =>
                          const ColoredBox(
                        color: Colors.black12,
                        child: Icon(Icons.eco),
                      ),
                    ),
            ),
          ),
          title: Text(
            entry.diseaseName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${_formatDate(entry.timestamp)}\n'
            'Severity: ${entry.severityPercentage.toStringAsFixed(1)}%',
            style: theme.textTheme.bodySmall,
          ),
          isThreeLine: true,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_statusIcon, color: _statusColor, size: 20),
              const SizedBox(height: 2),
              Text(
                entry.status.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _statusColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
