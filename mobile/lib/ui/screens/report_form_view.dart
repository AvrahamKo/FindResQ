import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/report_wire_format.dart';
import '../../core/providers.dart';
import '../../core/reports/report_state.dart';

const Map<String, String> _kindLabels = {
  'subject_found': 'Subject found',
  'medical': 'Medical emergency',
  'item_found': 'Item / clue found',
  'hazard': 'Hazard',
  'no_passage': 'No passage (terrain blocked)',
};

/// File a field report: pick a kind, add an optional note, submit. Grabs a
/// fresh GPS fix at submission time (see `ReportController.submit`) --
/// there's no manual location entry, matching the app's location model
/// throughout (a report's location is where you are when you file it).
class ReportFormView extends ConsumerStatefulWidget {
  /// Preselects the kind when the form is opened from the quick-report grid.
  /// Ignored if it isn't a known wire-format kind, so a bad value degrades
  /// to the default rather than putting the dropdown in a state with no
  /// matching item (which throws in [DropdownButtonFormField]).
  final String? initialKind;

  const ReportFormView({super.key, this.initialKind});

  @override
  ConsumerState<ReportFormView> createState() => _ReportFormViewState();
}

class _ReportFormViewState extends ConsumerState<ReportFormView> {
  late String _kind =
      reportKinds.contains(widget.initialKind) ? widget.initialKind! : reportKinds.first;
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reportControllerProvider);
    final notifier = ref.read(reportControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('File a report')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (state) {
          ReportSubmitting() => const Center(child: CircularProgressIndicator()),
          ReportSubmitted(:final kind) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 48),
                const SizedBox(height: 16),
                Text(
                  '${_kindLabels[kind] ?? kind} report sent.',
                  style: const TextStyle(fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('report_file_another_button'),
                  onPressed: notifier.reset,
                  child: const Text('File another report'),
                ),
              ],
            ),
          ),
          ReportError(:final message) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 40),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('report_error_dismiss'),
                  onPressed: notifier.reset,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
          ReportIdle() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('report_kind_field'),
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: reportKinds
                    .map(
                      (kind) => DropdownMenuItem(
                        value: kind,
                        child: Text(_kindLabels[kind] ?? kind),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _kind = value ?? _kind),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('report_note_field'),
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLength: reportMaxNoteChars,
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('report_submit_button'),
                onPressed: () => notifier.submit(
                  kind: _kind,
                  note: _noteController.text.trim(),
                ),
                child: const Text('Submit report'),
              ),
            ],
          ),
        },
      ),
    );
  }
}

/// A conservative character cap for the note field -- [maxNoteBytes] in
/// `report_wire_format.dart` is a BYTE cap (UTF-8), and a character can be
/// up to 4 bytes, so this stays well under it even for an all-emoji note.
const int reportMaxNoteChars = 250;
