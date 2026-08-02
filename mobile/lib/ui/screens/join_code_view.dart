import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Battery reading is user-entered in this phase rather than read from the
/// device -- real battery telemetry belongs with the location/device
/// services work (Phase 5c), not the join-flow UI.
const int _batteryBlockThreshold = 15;

class JoinCodeView extends ConsumerStatefulWidget {
  final bool isSubmitting;
  final String? errorMessage;

  const JoinCodeView({super.key, required this.isSubmitting, this.errorMessage});

  @override
  ConsumerState<JoinCodeView> createState() => _JoinCodeViewState();
}

class _JoinCodeViewState extends ConsumerState<JoinCodeView> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  String _movementMode = 'walker';
  int _batteryPct = 80;
  bool _powerbankAttested = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  bool get _needsPowerbankAttestation => _batteryPct <= _batteryBlockThreshold;

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    ref
        .read(joinControllerProvider.notifier)
        .submitJoinCode(
          code: _codeController.text.trim(),
          movementMode: _movementMode,
          batteryPct: _batteryPct,
          powerbankAttested: _powerbankAttested,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a sector')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                key: const Key('join_code_field'),
                controller: _codeController,
                keyboardType: TextInputType.number,
                enabled: !widget.isSubmitting,
                decoration: const InputDecoration(
                  labelText: 'Join code',
                  hintText: '6-digit code from your Sector Lead',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => RegExp(r'^\d{6}$').hasMatch(value ?? '')
                    ? null
                    : 'Enter the 6-digit join code',
              ),
              const SizedBox(height: 16),
              const Text('How are you searching?'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'walker', label: Text('Walker')),
                  ButtonSegment(value: 'vehicle', label: Text('Vehicle')),
                ],
                selected: {_movementMode},
                onSelectionChanged: widget.isSubmitting
                    ? null
                    : (selection) =>
                          setState(() => _movementMode = selection.first),
              ),
              const SizedBox(height: 16),
              Text('Battery: $_batteryPct%'),
              Slider(
                key: const Key('battery_slider'),
                value: _batteryPct.toDouble(),
                min: 0,
                max: 100,
                divisions: 100,
                label: '$_batteryPct%',
                onChanged: widget.isSubmitting
                    ? null
                    : (value) => setState(() {
                        _batteryPct = value.round();
                        if (!_needsPowerbankAttestation) {
                          _powerbankAttested = false;
                        }
                      }),
              ),
              if (_needsPowerbankAttestation)
                CheckboxListTile(
                  key: const Key('powerbank_checkbox'),
                  value: _powerbankAttested,
                  onChanged: widget.isSubmitting
                      ? null
                      : (value) =>
                            setState(() => _powerbankAttested = value ?? false),
                  title: const Text(
                    'Battery is at or below 15%. I have a power bank connected.',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              if (widget.errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  widget.errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('submit_join_button'),
                onPressed:
                    widget.isSubmitting ||
                        (_needsPowerbankAttestation && !_powerbankAttested)
                    ? null
                    : _submit,
                child: widget.isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Join sector'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
