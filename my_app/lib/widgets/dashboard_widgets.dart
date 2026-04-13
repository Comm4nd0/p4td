import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Overview stat card for the dashboard.
class OverviewCard extends StatefulWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const OverviewCard({super.key, required this.icon, required this.value, required this.label, required this.color, this.onTap});

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
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PhosphorIcon(widget.icon, color: widget.color, size: 20),
                const SizedBox(height: 8),
                Text(widget.value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                Text(widget.label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
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
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  const ActionItemTile({super.key, required this.icon, required this.label, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: PhosphorIcon(icon),
        title: Text(label),
        trailing: CircleAvatar(
          radius: 14,
          backgroundColor: Colors.grey[700],
          child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
        onTap: onTap,
      ),
    );
  }
}
