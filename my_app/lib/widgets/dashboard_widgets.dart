import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

/// Overview stat card for the dashboard.
class OverviewCard extends StatefulWidget {
  final PiconDuotoneData icon;
  final String value;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool compact;

  const OverviewCard({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
    this.onTap,
    this.compact = false,
  });

  @override
  State<OverviewCard> createState() => _OverviewCardState();
}

class _OverviewCardState extends State<OverviewCard> {
  bool _pressed = false;

  void _handleTap() async {
    if (widget.onTap == null) return;
    setState(() => _pressed = true);
    await Future.delayed(const Duration(milliseconds: 120));
    if (mounted) setState(() => _pressed = false);
    await Future.delayed(const Duration(milliseconds: 60));
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final padding = compact ? 8.0 : 16.0;
    final iconSize = compact ? 16.0 : 20.0;
    final valueSize = compact ? 18.0 : 28.0;
    final labelSize = compact ? 10.0 : 12.0;
    final gap = compact ? 2.0 : 8.0;

    return GestureDetector(
      onTapDown: widget.onTap != null ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.onTap != null ? (_) {} : null,
      onTapCancel: widget.onTap != null ? () => setState(() => _pressed = false) : null,
      onTap: _handleTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Picon(widget.icon, color: widget.color, size: iconSize),
                SizedBox(height: gap),
                Text(widget.value, style: TextStyle(fontSize: valueSize, fontWeight: FontWeight.bold)),
                Text(
                  widget.label,
                  style: TextStyle(fontSize: labelSize, color: Colors.grey[500]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Action item row tile for the dashboard.
class ActionItemTile extends StatelessWidget {
  final PiconDuotoneData icon;
  final String label;
  final int count;
  final VoidCallback onTap;
  final Color? countColor;

  const ActionItemTile({super.key, required this.icon, required this.label, required this.count, required this.onTap, this.countColor});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Picon(icon),
        title: Text(label),
        trailing: CircleAvatar(
          radius: 14,
          backgroundColor: countColor ?? Colors.grey[700],
          child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
        onTap: onTap,
      ),
    );
  }
}
