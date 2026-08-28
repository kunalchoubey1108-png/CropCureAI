import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/models/diagnosis_result.dart';
import 'escalation_service.dart';

/// Pending scans waiting for internet restoration to sync to KVK officers,
/// headed by the airplane-mode status indicator bar.
class ExpertQueueScreen extends StatefulWidget {
  const ExpertQueueScreen({
    super.key,
    this.connectivityProbe,
    this.extraActions = const [],
  });

  /// Extra app-bar actions injected by the shell (demo panel button).
  final List<Widget> extraActions;

  /// Injectable connectivity check (tests); defaults to the service's
  /// DNS-lookup probe.
  final Future<bool> Function()? connectivityProbe;

  @override
  State<ExpertQueueScreen> createState() => _ExpertQueueScreenState();
}

class _ExpertQueueScreenState extends State<ExpertQueueScreen> {
  final ExpertEscalationService _service = ExpertEscalationService.instance;

  List<DiagnosisResult> _pending = [];
  bool _loading = true;
  bool _online = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final pending = await _service.pending();
    final online =
        await (widget.connectivityProbe ?? _service.hasConnectivity)();
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _online = online;
      _loading = false;
    });
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final count = await _service.syncAll();
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Synced $count scan${count == 1 ? '' : 's'} to the KVK expert '
          'portal.',
        ),
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expert Review Queue'),
        actions: [
          ...widget.extraActions,
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _OfflineStatusBar(online: _online, queued: _pending.length),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _pending.isEmpty
                    ? const _EmptyQueue()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        itemCount: _pending.length,
                        itemBuilder: (context, i) => _QueuedScanCard(
                          result: _pending[i],
                          onRemove: () async {
                            await _service.remove(_pending[i]);
                            await _refresh();
                          },
                        ),
                      ),
          ),
        ],
      ),
      bottomNavigationBar: _pending.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _online && !_syncing ? _syncNow : null,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload),
                  label: Text(
                    _syncing
                        ? 'Syncing to KVK portal...'
                        : _online
                            ? 'Sync ${_pending.length} Scan'
                                '${_pending.length == 1 ? '' : 's'} Now'
                            : 'Waiting for network to sync...',
                  ),
                ),
              ),
            ),
    );
  }
}

/// "Airplane mode" banner: reassures that the app itself is fully offline
/// and reports how many scans wait for connectivity.
class _OfflineStatusBar extends StatelessWidget {
  const _OfflineStatusBar({required this.online, required this.queued});

  final bool online;
  final int queued;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.forestGreen : const Color(0xFF37474F);
    final text = online
        ? 'Back Online | $queued Scan${queued == 1 ? '' : 's'} Ready to '
            'Sync to KVK'
        : 'Core App 100% Offline | $queued Scan${queued == 1 ? '' : 's'} '
            'Queued for Expert Review when Online';
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              online ? Icons.wifi : Icons.airplanemode_active,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mark_email_read,
              size: 72,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Queue is empty',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Inconclusive or severe scans are stored here and sent to '
              'KVK agriculture experts when the phone is online.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedScanCard extends StatelessWidget {
  const _QueuedScanCard({required this.result, required this.onRemove});

  final DiagnosisResult result;
  final VoidCallback onRemove;

  String get _reasonLabel =>
      result.reliabilityState == ReliabilityState.lowConfidenceEscalate
          ? 'Inconclusive'
          : 'Severe case';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imagePath = result.imagePath ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 52,
            height: 52,
            child: imagePath.isEmpty
                ? const ColoredBox(
                    color: Colors.black12,
                    child: Icon(Icons.image_not_supported),
                  )
                : Image.file(
                    File(imagePath),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.eco),
                    ),
                  ),
          ),
        ),
        title: Text(
          result.className.replaceAll('___', ' ').replaceAll('_', ' '),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$_reasonLabel · '
          '${(result.confidenceScore * 100).toStringAsFixed(0)}% confidence\n'
          'Queued ${result.timestamp.day}/${result.timestamp.month}/'
          '${result.timestamp.year}',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: IconButton(
          tooltip: 'Remove from queue',
          onPressed: onRemove,
          icon: const Icon(Icons.close),
        ),
      ),
    );
  }
}
