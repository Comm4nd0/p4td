import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../screens/enquiry_screen.dart';

/// Compiled-in detail copy for each public service, shown when a visitor taps
/// a service card on the logged-out landing page. Content is condensed from
/// the website (services.html / field_hire.html / SiteSettings defaults) —
/// keep the two in step when the marketing copy changes.
class ServiceDetail {
  final String code; // ContactInquiry.SERVICE_CHOICES code for the enquiry form
  final String title;
  final PiconDuotoneData icon;
  final String intro;
  final List<String> bullets;

  const ServiceDetail({
    required this.code,
    required this.title,
    required this.icon,
    required this.intro,
    required this.bullets,
  });

  static const dayCare = ServiceDetail(
    code: 'daycare',
    title: 'Day Care',
    icon: PiconsDuotone.pawPrint,
    intro: 'The very best day, every day. Set across 10 secure, '
        'council-licensed acres, your dog enjoys a full programme of play, '
        'rest and enrichment with our experienced team.',
    bullets: [
      'Supervised group play in spacious outdoor fields',
      'Dogs grouped by size and temperament',
      'Positive socialisation with other dogs',
      'Feeding as per your instructions',
      'Structured rest periods and enrichment',
      'Photos and updates during the day',
      'Pick-up and drop-off service available',
    ],
  );

  static const training = ServiceDetail(
    code: 'one2one',
    title: '1-to-1 Training',
    icon: PiconsDuotone.graduationCap,
    intro: 'One-to-one sessions designed around your dog\'s needs and '
        'personality, using force-free, positive reinforcement methods. '
        'On-site, at home, or wherever your dog feels most comfortable.',
    bullets: [
      'Puppy foundation training',
      'Recall and lead manners',
      'Reactive dog support',
      'Separation anxiety',
      'General obedience and life skills',
    ],
  );

  static const puppyClasses = ServiceDetail(
    code: 'puppy_classes',
    title: 'Puppy Classes',
    icon: PiconsDuotone.dog,
    intro: 'A four-week on-site course giving your puppy the best start in '
        'life, using positive reinforcement throughout.',
    bullets: [
      'Basic commands — sit, stay, come, loose-lead walking',
      'Socialisation with dogs and people',
      'A structured, safe environment to learn',
      'Time to bond with your puppy',
    ],
  );

  static const fieldHire = ServiceDetail(
    code: 'field_hire',
    title: 'Field Hire',
    icon: PiconsDuotone.park,
    intro: 'Hire our fully enclosed 5-acre field exclusively for your dog — '
        'perfect for reactive or nervous dogs who need space to run safely.',
    bullets: [
      '5 acres of open, secure space to roam',
      'Fully fenced for safety',
      'Ample on-site parking',
      'Booked in one-hour slots',
      'Please collect all dog waste during your visit',
    ],
  );
}

/// Bottom sheet with the full description of one service, plus a shortcut to
/// the enquiry form pre-set to that service.
class ServiceDetailSheet extends StatelessWidget {
  final ServiceDetail detail;

  const ServiceDetailSheet({super.key, required this.detail});

  static Future<void> show(BuildContext context, ServiceDetail detail) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ServiceDetailSheet(detail: detail),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.grey600 : AppColors.grey300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppColors.primaryLight.withValues(alpha: 0.15)
                          : AppColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Picon(detail.icon, size: 28, color: AppColors.primaryLight),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      detail.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppColors.cream : AppColors.primaryDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                detail.intro,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 16),
              for (final bullet in detail.bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Picon(PiconsDuotone.checkCircle,
                            size: 18, color: AppColors.primaryLight),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          bullet,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isDark ? AppColors.grey400 : AppColors.grey700,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EnquiryScreen(initialService: detail.code),
                      ),
                    );
                  },
                  icon: const Picon(PiconsDuotone.chatCircle, size: 20),
                  label: const Text('Make an Enquiry'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle:
                        const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
