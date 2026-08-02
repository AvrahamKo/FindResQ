import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

class OtpEntryView extends ConsumerStatefulWidget {
  final String phoneE164;
  final String? devCode;
  final bool isVerifying;
  final String? errorMessage;

  const OtpEntryView({
    super.key,
    required this.phoneE164,
    required this.isVerifying,
    this.devCode,
    this.errorMessage,
  });

  @override
  ConsumerState<OtpEntryView> createState() => _OtpEntryViewState();
}

class _OtpEntryViewState extends ConsumerState<OtpEntryView> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    // Local dev convenience: pre-fill the code the backend echoed back so
    // the flow can be exercised without a real SMS provider.
    _controller = TextEditingController(text: widget.devCode ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    if (!RegExp(r'^\d{6}$').hasMatch(value ?? '')) {
      return 'Enter the 6-digit code';
    }
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    ref.read(authControllerProvider.notifier).verifyOtp(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter code')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('A 6-digit code was sent to ${widget.phoneE164}'),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('otp_field'),
                controller: _controller,
                keyboardType: TextInputType.number,
                enabled: !widget.isVerifying,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                  border: OutlineInputBorder(),
                ),
                validator: _validate,
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
                key: const Key('verify_otp_button'),
                onPressed: widget.isVerifying ? null : _submit,
                child: widget.isVerifying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Verify'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
