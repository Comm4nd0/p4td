import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import 'login_screen.dart';
import 'register_screen.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Hero section ──────────────────────────────────────
              _buildHeroSection(context, isDark),

              // ── Services section ──────────────────────────────────
              _buildServicesSection(context, isDark),

              // ── Why choose us ─────────────────────────────────────
              _buildTrustSection(context, isDark),

              // ── App features ──────────────────────────────────────
              _buildAppFeaturesSection(context, isDark),

              // ── CTA section ───────────────────────────────────────
              _buildCtaSection(context, isDark),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroSection(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [AppColors.darkSurface, AppColors.darkBackground]
              : [AppColors.primary, AppColors.primaryDark],
        ),
      ),
      child: Column(
        children: [
          // Logo
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Image.asset('assets/logo.png', height: 80),
          ),
          const SizedBox(height: 24),
          // Tagline
          Text(
            'Where Happy Dogs\nCome to Play',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: AppColors.cream,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            'Safe, fun day care in Berkshire & Buckinghamshire',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.cream.withValues(alpha: 0.85),
                ),
          ),
          const SizedBox(height: 28),
          // CTA buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
                  icon: const Picon(PiconsDuotone.signIn, size: 20),
                  label: const Text('Log In'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.primaryDark,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  ),
                  icon: const Picon(PiconsDuotone.userPlus, size: 20),
                  label: const Text('Register'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServicesSection(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 8),
      child: Column(
        children: [
          Text(
            'Our Services',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppColors.cream : AppColors.primaryDark,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Everything your dog needs, all in one place',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppColors.grey400 : AppColors.grey600,
                ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _ServiceCard(
                  icon: PiconsDuotone.pawPrint,
                  title: 'Day Care',
                  description: 'Supervised group play across 10 secure, licensed acres',
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ServiceCard(
                  icon: PiconsDuotone.graduationCap,
                  title: 'Training',
                  description: '1-to-1 sessions using positive reinforcement methods',
                  isDark: isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ServiceCard(
                  icon: PiconsDuotone.dog,
                  title: 'Puppy Classes',
                  description: 'Foundation training and socialisation for puppies',
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ServiceCard(
                  icon: PiconsDuotone.park,
                  title: 'Field Hire',
                  description: 'Private hire of our secure 10-acre enclosed field',
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrustSection(BuildContext context, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.darkSurfaceVariant
            : AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppColors.primaryLight.withValues(alpha: 0.2)
              : AppColors.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        children: [
          Text(
            'Why Choose Us',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppColors.cream : AppColors.primaryDark,
                ),
          ),
          const SizedBox(height: 16),
          _TrustRow(
            icon: PiconsDuotone.shieldCheck,
            title: 'Licensed & Insured',
            description: 'Council-licensed facility with full insurance cover',
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          _TrustRow(
            icon: PiconsDuotone.users,
            title: 'Experienced Staff',
            description: 'Qualified team caring for dogs of all breeds and temperaments',
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          _TrustRow(
            icon: PiconsDuotone.tree,
            title: '10 Acres of Space',
            description: 'Fully enclosed, secure outdoor fields for dogs to run and explore',
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          _TrustRow(
            icon: PiconsDuotone.heart,
            title: 'Force-Free Training',
            description: 'Positive reinforcement only -- never punishment-based methods',
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _buildAppFeaturesSection(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        children: [
          Text(
            'What You Get With the App',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppColors.cream : AppColors.primaryDark,
                ),
          ),
          const SizedBox(height: 16),
          _AppFeatureTile(
            icon: PiconsDuotone.camera,
            title: 'Daily Photos & Updates',
            description: 'See what your dog gets up to during their day with us',
            isDark: isDark,
          ),
          _AppFeatureTile(
            icon: PiconsDuotone.calendarCheck,
            title: 'Manage Bookings',
            description: 'View your schedule, request date changes, and book boarding',
            isDark: isDark,
          ),
          _AppFeatureTile(
            icon: PiconsDuotone.bell,
            title: 'Instant Notifications',
            description: 'Get notified about pickups, schedule changes, and updates',
            isDark: isDark,
          ),
          _AppFeatureTile(
            icon: PiconsDuotone.chatCircle,
            title: 'Direct Support',
            description: 'Message our team directly through the app anytime',
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _buildCtaSection(BuildContext context, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [AppColors.darkSurface, AppColors.darkSurfaceVariant]
              : [AppColors.primary, AppColors.primaryLight],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Picon(
            PiconsDuotone.pawPrint,
            size: 40,
            color: AppColors.cream.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 12),
          Text(
            'Ready to get started?',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Create an account or log in to manage your bookings',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.8),
                ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RegisterScreen()),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.primaryDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Create an Account'),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            ),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Already have an account? Log in'),
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ──────────────────────────────────────────────────

class _ServiceCard extends StatelessWidget {
  final PiconDuotoneData icon;
  final String title;
  final String description;
  final bool isDark;

  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppColors.darkSurfaceVariant : AppColors.grey300,
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.primaryLight.withValues(alpha: 0.15)
                  : AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Picon(icon, size: 28, color: AppColors.primaryLight),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isDark ? AppColors.grey400 : AppColors.grey600,
                  height: 1.3,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _TrustRow extends StatelessWidget {
  final PiconDuotoneData icon;
  final String title;
  final String description;
  final bool isDark;

  const _TrustRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.primaryLight.withValues(alpha: 0.15)
                : AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Picon(icon, size: 22, color: AppColors.primaryLight),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isDark ? AppColors.grey400 : AppColors.grey600,
                      height: 1.3,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AppFeatureTile extends StatelessWidget {
  final PiconDuotoneData icon;
  final String title;
  final String description;
  final bool isDark;

  const _AppFeatureTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? AppColors.darkSurfaceVariant : AppColors.grey300,
              ),
            ),
            child: Picon(icon, size: 24, color: AppColors.primaryLight),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark ? AppColors.grey400 : AppColors.grey600,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
