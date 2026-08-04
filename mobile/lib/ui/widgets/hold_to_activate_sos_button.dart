import 'package:flutter/material.dart';

/// How long the button must be held before SOS fires.
///
/// Long enough that a pocket-brush or a fumbled tap can't send a distress
/// signal, short enough to be usable one-handed, in the dark, by someone who
/// is scared. The hold replaces the confirmation DIALOG used elsewhere
/// (`SosButtonView`) on purpose: a dialog needs a second accurate tap on a
/// small target, which is the harder action in exactly the conditions where
/// this button matters.
const Duration sosHoldDuration = Duration(milliseconds: 1500);

/// Large press-and-hold SOS control with a filling progress ring.
///
/// Releasing early cancels and resets to zero -- and is silent, since a
/// half-press is almost always accidental and an "SOS cancelled" toast every
/// time a phone shifts in a pocket would train searchers to ignore the UI.
class HoldToActivateSosButton extends StatefulWidget {
  /// Fired once, only after a full [sosHoldDuration] hold completes.
  final VoidCallback onActivate;

  /// Disables the control (already sending, or an SOS is already open).
  final bool enabled;

  /// Replaces the label when an alert is already open.
  final String label;

  const HoldToActivateSosButton({
    super.key,
    required this.onActivate,
    this.enabled = true,
    this.label = 'HOLD FOR SOS',
  });

  @override
  State<HoldToActivateSosButton> createState() =>
      _HoldToActivateSosButtonState();
}

class _HoldToActivateSosButtonState extends State<HoldToActivateSosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: sosHoldDuration,
  )..addStatusListener(_onStatusChanged);

  void _onStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // Reset before notifying so a rebuild triggered by onActivate can't
    // observe a full ring that would re-fire on the next status event.
    _controller.value = 0;
    widget.onActivate();
  }

  void _startHold() {
    if (!widget.enabled) return;
    _controller.forward(from: 0);
  }

  /// Rewinds rather than jumping to zero: the ring visibly unwinding is the
  /// feedback that the hold was released too early.
  void _cancelHold() => _controller.reverse();

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) => _startHold(),
        onTapUp: (_) => _cancelHold(),
        onTapCancel: _cancelHold,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = _controller.value;
            return SizedBox(
              height: 132,
              width: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      key: const Key('sos_hold_progress'),
                      value: progress,
                      strokeWidth: 6,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? Color.lerp(
                              const Color(0xFFC0392B),
                              const Color(0xFFFF5C4D),
                              progress,
                            )
                          : Colors.grey.shade700,
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        widget.label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
