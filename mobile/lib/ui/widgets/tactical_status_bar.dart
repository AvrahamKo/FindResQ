import 'package:flutter/material.dart';

/// Severity drives colour only -- never the presence of a field. A searcher
/// glancing at this bar in bad light needs the same four slots in the same
/// four places every time.
enum StatusLevel { good, warn, bad, unknown }

Color _colorFor(StatusLevel level) => switch (level) {
  StatusLevel.good => const Color(0xFF2ECC71),
  StatusLevel.warn => const Color(0xFFF1C40F),
  StatusLevel.bad => const Color(0xFFE74C3C),
  StatusLevel.unknown => const Color(0xFF8B95A1),
};

class StatusChipData {
  final IconData icon;
  final String label;
  final StatusLevel level;

  const StatusChipData({
    required this.icon,
    required this.label,
    required this.level,
  });
}

/// Top-of-screen situational bar: sector, GPS, battery, uplink.
///
/// Every value is shown as text alongside its icon rather than colour alone
/// -- colour is a redundant cue here, not the carrier of the information
/// (colour-blind users, and washed-out screens in direct sunlight, are both
/// ordinary field conditions).
class TacticalStatusBar extends StatelessWidget {
  final String sectorName;
  final StatusChipData gps;
  final StatusChipData battery;
  final StatusChipData uplink;

  const TacticalStatusBar({
    super.key,
    required this.sectorName,
    required this.gps,
    required this.battery,
    required this.uplink,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF161B22),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.my_location, size: 14, color: Color(0xFF8B95A1)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      sectorName,
                      key: const Key('status_sector_name'),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _Chip(data: gps, chipKey: const Key('status_gps')),
                  const SizedBox(width: 8),
                  _Chip(data: battery, chipKey: const Key('status_battery')),
                  const SizedBox(width: 8),
                  _Chip(data: uplink, chipKey: const Key('status_uplink')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final StatusChipData data;
  final Key chipKey;

  const _Chip({required this.data, required this.chipKey});

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(data.level);
    return Container(
      key: chipKey,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(data.icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            data.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
