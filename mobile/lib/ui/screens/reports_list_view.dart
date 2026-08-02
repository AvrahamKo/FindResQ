import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/reports/reports_list_state.dart';

const _pollInterval = Duration(seconds: 5);

/// Any sector member's view of the sector's field reports -- unlike
/// `SosAlertsView`, this is NOT restricted to Lead/Commander (see
/// `ApiClient.listSectorReports`'s docstring); only the Acknowledge action
/// is. UI-driven polling, same convention as `SosAlertsView`.
class ReportsListView extends ConsumerStatefulWidget {
  const ReportsListView({super.key});

  @override
  ConsumerState<ReportsListView> createState() => _ReportsListViewState();
}

class _ReportsListViewState extends ConsumerState<ReportsListView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(reportsListControllerProvider.notifier).load());
    _timer = Timer.periodic(
      _pollInterval,
      (_) => ref.read(reportsListControllerProvider.notifier).load(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reportsListControllerProvider);
    final notifier = ref.read(reportsListControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Sector reports')),
      body: switch (state) {
        ReportsListLoading() => const Center(child: CircularProgressIndicator()),
        ReportsListFailed(:final message) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, textAlign: TextAlign.center),
          ),
        ),
        ReportsListLoaded(:final reports) when reports.isEmpty => const Center(
          child: Text('No reports for this sector yet.'),
        ),
        ReportsListLoaded(:final reports) => ListView.builder(
          itemCount: reports.length,
          itemBuilder: (context, index) {
            final report = reports[index];
            return ListTile(
              key: Key('report_${report.id}'),
              leading: Icon(
                Icons.flag,
                color: report.status == 'open' ? Colors.orange : Colors.grey,
              ),
              title: Text(report.kind),
              subtitle: Text(
                report.note?.isNotEmpty == true
                    ? report.note!
                    : '${report.lat.toStringAsFixed(5)}, ${report.lng.toStringAsFixed(5)}',
              ),
              trailing: report.status == 'open'
                  ? FilledButton(
                      key: Key('report_acknowledge_${report.id}'),
                      onPressed: () => notifier.acknowledge(report.id),
                      child: const Text('Acknowledge'),
                    )
                  : const Icon(Icons.check, color: Colors.green),
            );
          },
        ),
      },
    );
  }
}
