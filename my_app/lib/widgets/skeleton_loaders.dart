import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

// ── Helper ──────────────────────────────────────────────────────────

/// A rounded rectangle placeholder used inside shimmer wrappers.
class _Bone extends StatelessWidget {
  final double width;
  final double height;
  final double radius;

  const _Bone({
    required this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[300],
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Wraps its child in a [Shimmer] animation.
class ShimmerWrap extends StatelessWidget {
  final Widget child;
  const ShimmerWrap({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark ? Colors.grey[800]! : Colors.grey[300]!,
      highlightColor: isDark ? Colors.grey[700]! : Colors.grey[100]!,
      child: child,
    );
  }
}

// ── Feed card skeleton ──────────────────────────────────────────────

/// Matches the layout of [FeedItemCard].
class FeedCardSkeleton extends StatelessWidget {
  const FeedCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerWrap(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Card(
          elevation: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: avatar + name + timestamp
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const _Bone(width: 40, height: 40, radius: 20),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _Bone(width: 100, height: 14),
                        SizedBox(height: 6),
                        _Bone(width: 60, height: 10),
                      ],
                    ),
                  ],
                ),
              ),
              // Image placeholder
              const _Bone(width: double.infinity, height: 250, radius: 0),
              // Caption lines
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _Bone(width: double.infinity, height: 14),
                    SizedBox(height: 8),
                    _Bone(width: 200, height: 14),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Dog card skeleton ───────────────────────────────────────────────

/// Matches the layout of dog list cards in HomeScreen.
class DogCardSkeleton extends StatelessWidget {
  const DogCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerWrap(
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _Bone(width: double.infinity, height: 200, radius: 4),
            Padding(
              padding: EdgeInsets.all(16),
              child: _Bone(width: 140, height: 22),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Generic list tile skeleton ──────────────────────────────────────

/// Matches a standard list tile layout for requests, queries, inquiries.
class ListTileSkeleton extends StatelessWidget {
  const ListTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerWrap(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const _Bone(width: 40, height: 40, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _Bone(width: double.infinity, height: 14),
                  SizedBox(height: 8),
                  _Bone(width: 160, height: 12),
                  SizedBox(height: 6),
                  _Bone(width: 100, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Convenience list builders ───────────────────────────────────────

/// Shows [count] feed card skeletons in a scrollable list.
class FeedSkeletonList extends StatelessWidget {
  final int count;
  const FeedSkeletonList({super.key, this.count = 3});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (_, __) => const FeedCardSkeleton(),
    );
  }
}

/// Shows [count] dog card skeletons.
class DogSkeletonList extends StatelessWidget {
  final int count;
  const DogSkeletonList({super.key, this.count = 4});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      itemCount: count,
      itemBuilder: (_, __) => const DogCardSkeleton(),
    );
  }
}

/// Shows [count] list tile skeletons.
class ListTileSkeletonList extends StatelessWidget {
  final int count;
  const ListTileSkeletonList({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (_, __) => const ListTileSkeleton(),
    );
  }
}
