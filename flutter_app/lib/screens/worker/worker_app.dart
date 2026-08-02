import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../data/worker_professional_categories.dart';
import '../../models/worker_models.dart';
import '../../providers/worker_provider.dart';
import '../../services/worker_document_extraction_service.dart';
import '../../services/worker_dispatch_service.dart';
import 'worker_liveness_capture.dart';
import '../../widgets/worker_voice_guide.dart';

bool _isHindi(WidgetRef ref) {
  return ref.watch(workerControllerProvider).application.language == 'Hindi';
}

String _copy(WidgetRef ref, String english, String hindi) {
  return _isHindi(ref) ? hindi : english;
}

class WorkerRoot extends ConsumerWidget {
  const WorkerRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);

    if (state.restoringSession) {
      return const WorkerSessionRestoreScreen();
    }

    if (!state.phoneVerified) {
      return const WorkerLoginScreen();
    }

    if (state.existingEnrollment?.workerStatus == 'verified') {
      return const WorkerShell();
    }

    if (state.existingEnrollment != null) {
      return const ExistingEnrollmentScreen();
    }

    if (state.application.status == WorkerReviewStatus.approved) {
      return const WorkerShell();
    }

    if (state.application.status == WorkerReviewStatus.underReview) {
      return const WorkerReviewScreen();
    }

    return const WorkerOnboardingScreen();
  }
}

String _workerLoginPrompt(WorkerState state) {
  if (!state.otpSent) {
    return 'अपना दस अंकों का मोबाइल नंबर डालें। फिर गेट ओ टी पी दबाएं।';
  }
  return 'ओ टी पी डालें। फिर वेरीफाई ओ टी पी दबाएं।';
}

String _workerStepPrompt(WorkerState state) {
  final app = state.application;
  return switch (state.onboardingStep) {
    0 => 'अपनी भाषा चुनें।',
    1 => _profilePrompt(app),
    2 => _skillsPrompt(app),
    3 => _documentsPrompt(app),
    _ => 'सहमति बॉक्स टिक करें। फिर समीक्षा के लिए सबमिट करें।',
  };
}

String _profilePrompt(WorkerApplication app) {
  if (app.fullName.trim().isEmpty) return 'अपना पूरा नाम भरें।';
  if (app.age.trim().isEmpty) return 'अपनी उम्र भरें।';
  if (app.city.trim().isEmpty) return 'अपना शहर चुनें।';
  if (app.workArea.trim().isEmpty) return 'अपना काम का क्षेत्र चुनें।';
  return 'जारी रखें दबाएं।';
}

String _skillsPrompt(WorkerApplication app) {
  if (!app.enrolledAsHelper && !app.enrolledAsProfessional) {
    return 'हेल्पर या प्रोफेशनल में से एक विकल्प चुनें।';
  }
  if (app.enrolledAsProfessional && app.professionalCategories.isEmpty) {
    return 'अपनी प्रोफेशनल कैटेगरी चुनें।';
  }
  return 'यात्रा दूरी चुनें। फिर जारी रखें दबाएं।';
}

String _documentsPrompt(WorkerApplication app) {
  if (app.idType == null) {
    return 'पहले आई डी का प्रकार चुनें।';
  }
  if (!app.documents.containsKey(WorkerDocumentType.nationalIdFront)) {
    return '${app.idType!.label} की सामने वाली फोटो जोड़ें।';
  }
  if (!app.documents.containsKey(WorkerDocumentType.nationalIdBack)) {
    return '${app.idType!.label} की पीछे वाली फोटो जोड़ें।';
  }
  if (!app.documents.containsKey(WorkerDocumentType.selfie)) {
    return 'अपनी साफ सेल्फी जोड़ें।';
  }
  return 'जारी रखें दबाएं।';
}

const _workerReviewPrompt = 'समीक्षा पूरी होने तक प्रतीक्षा करें।';

class WorkerLoginScreen extends ConsumerStatefulWidget {
  const WorkerLoginScreen({super.key});

  @override
  ConsumerState<WorkerLoginScreen> createState() => _WorkerLoginScreenState();
}

class _WorkerLoginScreenState extends ConsumerState<WorkerLoginScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(workerControllerProvider);

    return WorkerVoiceGuide(
      prompt: _workerLoginPrompt(state),
      enabled: false,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 28),
              Text('Workida Worker', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text(
                'Join Workida to get local work requests after verification.',
              ),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Enter mobile number',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _phoneController,
                        enabled: !state.otpSent,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(10),
                        ],
                        decoration: const InputDecoration(
                          prefixText: '+91 ',
                          prefixIcon: Icon(Icons.phone_outlined),
                          hintText: '10 digit mobile number',
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (state.otpSent) ...[
                        TextField(
                          controller: _otpController,
                          keyboardType: TextInputType.number,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.lock_outline),
                            hintText: 'Enter 6 digit OTP',
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      FilledButton.icon(
                        onPressed: state.checkingEnrollmentStatus
                            ? null
                            : state.otpSent
                                ? _verifyOtp
                                : _sendOtp,
                        icon: Icon(
                          state.checkingEnrollmentStatus
                              ? Icons.hourglass_top
                              : state.otpSent
                                  ? Icons.verified_outlined
                                  : Icons.sms_outlined,
                        ),
                        label: Text(
                          state.checkingEnrollmentStatus
                              ? 'Checking enrollment'
                              : state.otpSent
                                  ? 'Verify OTP'
                                  : 'Get OTP',
                        ),
                      ),
                      if (state.enrollmentError != null)
                        _FieldErrorText(text: state.enrollmentError!),
                      if (!state.otpSent && state.enrollmentError != null)
                        TextButton(
                          onPressed: state.checkingEnrollmentStatus
                              ? null
                              : _sendOtp,
                          child: const Text('Try again'),
                        ),
                      if (state.otpSent)
                        TextButton(
                          onPressed: _resendOtp,
                          child: const Text('Resend OTP'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _HelpStrip(
                text: 'No email or password needed. Phone OTP is enough.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendOtp() async {
    final phone = _phoneController.text.trim();
    final controller = ref.read(workerControllerProvider.notifier);
    final validationError = controller.validatePhone(phone);
    if (validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validationError)),
      );
      return;
    }
    final error = await controller.requestOtp(phone);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Verification code sent by SMS.')),
    );
  }

  void _resendOtp() {
    _otpController.clear();
    _sendOtp();
  }

  Future<void> _verifyOtp() async {
    final error = await ref
        .read(workerControllerProvider.notifier)
        .verifyOtpAndCheckEnrollment(_otpController.text.trim());
    if (!mounted) return;
    if (error != null) {
      _otpController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Phone verified successfully.')),
    );
  }
}

class WorkerSessionRestoreScreen extends StatelessWidget {
  const WorkerSessionRestoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Checking worker session...'),
            ],
          ),
        ),
      ),
    );
  }
}

class ExistingEnrollmentScreen extends ConsumerWidget {
  const ExistingEnrollmentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrollment = ref.watch(workerControllerProvider).existingEnrollment!;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 28),
            Icon(
              _statusIcon(enrollment),
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 18),
            Text(
              _statusTitle(enrollment),
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(_statusMessage(enrollment)),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _InfoRow(
                      icon: Icons.person_outline,
                      text: enrollment.fullName.isEmpty
                          ? 'Worker profile found'
                          : enrollment.fullName,
                    ),
                    _InfoRow(
                      icon: Icons.verified_user_outlined,
                      text: 'Worker status: ${enrollment.workerStatus}',
                    ),
                    _InfoRow(
                      icon: Icons.fact_check_outlined,
                      text: 'KYC status: ${enrollment.kycStatus}',
                    ),
                    if (enrollment.submittedAt != null)
                      _InfoRow(
                        icon: Icons.schedule_outlined,
                        text: 'Submitted: ${enrollment.submittedAt!.toLocal()}',
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            const _HelpStrip(
              text:
                  'This mobile number already has a worker enrollment. Contact Workida support if this is not you.',
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () {
                ref.read(workerControllerProvider.notifier).clearSession();
              },
              icon: const Icon(Icons.logout_outlined),
              label: const Text('Use another phone number'),
            ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(ExistingWorkerEnrollment enrollment) {
    return switch (enrollment.workerStatus) {
      'verified' => Icons.verified,
      'rejected' => Icons.cancel_outlined,
      'manual_review' => Icons.manage_search_outlined,
      _ => Icons.hourglass_top,
    };
  }

  String _statusTitle(ExistingWorkerEnrollment enrollment) {
    return switch (enrollment.workerStatus) {
      'verified' => 'You are already verified',
      'rejected' => 'Enrollment was rejected',
      'manual_review' => 'Manual review in progress',
      _ => 'Enrollment already submitted',
    };
  }

  String _statusMessage(ExistingWorkerEnrollment enrollment) {
    return switch (enrollment.workerStatus) {
      'verified' =>
        'Your worker profile is already verified. You do not need to enroll again.',
      'rejected' =>
        'Your previous enrollment was rejected. Please contact Workida support before reapplying.',
      'manual_review' =>
        'Workida admin is reviewing your verification details. Please wait for an update.',
      _ =>
        'Your worker application is already under review. Duplicate enrollment is not allowed.',
    };
  }
}

class WorkerOnboardingScreen extends ConsumerWidget {
  const WorkerOnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);
    final step = state.onboardingStep;
    final hindi = _isHindi(ref);

    final scaffold = Scaffold(
      appBar:
          AppBar(title: Text(_copy(ref, 'Worker enrollment', 'वर्कर नामांकन'))),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hindi ? 'चरण ${step + 1} / 5' : 'Step ${step + 1} of 5',
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: (step + 1) / 5),
                ],
              ),
            ),
            Expanded(
              child: switch (step) {
                0 => const _LanguageStep(),
                1 => const _ProfileStep(),
                2 => const _SkillsStep(),
                3 => const _ConsentStep(),
                _ => const _DocumentsStep(),
              },
            ),
          ],
        ),
      ),
    );

    if (step == 1) {
      return scaffold;
    }

    return WorkerVoiceGuide(
      prompt: _workerStepPrompt(state),
      enabled: _isHindi(ref),
      child: scaffold,
    );
  }
}

class _LanguageStep extends ConsumerWidget {
  const _LanguageStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _StepScaffold(
      icon: Icons.translate,
      title: 'Choose language',
      message: 'Pick the language you are comfortable with.',
      children: [
        _BigChoice(
          icon: Icons.language,
          title: 'English',
          subtitle: 'Continue in English',
          onTap: () => ref
              .read(workerControllerProvider.notifier)
              .selectLanguage('English'),
        ),
        _BigChoice(
          icon: Icons.record_voice_over_outlined,
          title: 'Hindi',
          subtitle: 'आगे की स्क्रीन हिंदी में देखें',
          onTap: () => ref
              .read(workerControllerProvider.notifier)
              .selectLanguage('Hindi'),
        ),
      ],
    );
  }
}

class _ProfileStep extends ConsumerStatefulWidget {
  const _ProfileStep();

  @override
  ConsumerState<_ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends ConsumerState<_ProfileStep> {
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _emergencyController = TextEditingController();
  String? _selectedCity;
  String? _selectedArea;

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _emergencyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WorkerVoiceGuide(
      prompt: _localProfilePrompt,
      enabled: _isHindi(ref),
      child: _StepScaffold(
        icon: Icons.badge_outlined,
        title: _copy(ref, 'Tell us about you', 'अपने बारे में बताएं'),
        message: _copy(
          ref,
          'Use simple details. Workida will verify them before approval.',
          'सरल जानकारी भरें। मंजूरी से पहले Gofer इसे सत्यापित करेगा।',
        ),
        children: [
          _TextInput(
            controller: _nameController,
            label: _copy(ref, 'Full name', 'पूरा नाम'),
            icon: Icons.person_outline,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          _TextInput(
            controller: _ageController,
            label: _copy(ref, 'Age', 'उम्र'),
            icon: Icons.cake_outlined,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          DropdownMenu<String>(
            width: double.infinity,
            initialSelection: _selectedCity,
            label: Text(_copy(ref, 'City', 'शहर')),
            leadingIcon: const Icon(Icons.location_city_outlined),
            dropdownMenuEntries: _cityAreas.keys
                .map(
                  (city) => DropdownMenuEntry<String>(
                    value: city,
                    label: city,
                  ),
                )
                .toList(),
            onSelected: (city) {
              setState(() {
                _selectedCity = city;
                _selectedArea = null;
              });
            },
          ),
          DropdownMenu<String>(
            width: double.infinity,
            key: ValueKey(_selectedCity),
            enabled: _selectedCity != null,
            initialSelection: _selectedArea,
            label: Text(_copy(ref, 'Work area', 'काम का क्षेत्र')),
            leadingIcon: const Icon(Icons.map_outlined),
            dropdownMenuEntries: (_cityAreas[_selectedCity] ?? const <String>[])
                .map(
                  (area) => DropdownMenuEntry<String>(
                    value: area,
                    label: area,
                  ),
                )
                .toList(),
            onSelected: (area) => setState(() => _selectedArea = area),
          ),
          _TextInput(
            controller: _emergencyController,
            label: _copy(ref, 'Emergency contact (optional)',
                'आपातकालीन संपर्क (वैकल्पिक)'),
            icon: Icons.contact_phone_outlined,
            keyboardType: TextInputType.phone,
          ),
          FilledButton(
            onPressed: _save,
            child: Text(_copy(ref, 'Continue', 'जारी रखें')),
          ),
        ],
      ),
    );
  }

  void _save() {
    final hindi = _isHindi(ref);
    if (_nameController.text.trim().isEmpty ||
        _ageController.text.trim().isEmpty ||
        _selectedCity == null ||
        _selectedArea == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hindi
                ? 'कृपया नाम, उम्र, शहर और काम का क्षेत्र भरें।'
                : 'Please fill name, age, city and work area.',
          ),
        ),
      );
      return;
    }

    ref.read(workerControllerProvider.notifier).saveProfile(
          fullName: _nameController.text.trim(),
          age: _ageController.text.trim(),
          city: _selectedCity!,
          workArea: _selectedArea!,
          emergencyContact: _emergencyController.text.trim(),
        );
  }

  String get _localProfilePrompt {
    if (_nameController.text.trim().isEmpty) return 'अपना पूरा नाम भरें।';
    if (_ageController.text.trim().isEmpty) return 'अपनी उम्र भरें।';
    if (_selectedCity == null) return 'अपना शहर चुनें।';
    if (_selectedArea == null) return 'अपना काम का क्षेत्र चुनें।';
    return 'जारी रखें दबाएं।';
  }
}

const Map<String, List<String>> _cityAreas = {
  'Indore': [
    'Vijay Nagar',
    'Palasia',
    'Bhawarkuan',
    'Rajwada',
    'MG Road',
    'Rau',
    'Sudama Nagar',
    'Scheme No. 54',
    'Scheme No. 78',
    'Annapurna Road',
    'Bengali Square',
    'Geeta Bhawan',
    'MR 10',
    'Nipania',
    'Kanadia Road',
  ],
  'Patna': [
    'Boring Road',
    'Kankarbagh',
    'Patliputra Colony',
    'Bailey Road',
    'Rajendra Nagar',
    'Fraser Road',
    'Danapur',
    'Ashiana Nagar',
    'Kidwaipuri',
    'Patna City',
    'Gola Road',
    'Saguna More',
    'Phulwari Sharif',
    'Anisabad',
    'Kadamkuan',
  ],
  'Gurugram': [
    'DLF Phase 1',
    'DLF Phase 2',
    'DLF Phase 3',
    'DLF Phase 4',
    'DLF Phase 5',
    'Sector 14',
    'Sector 29',
    'Sector 31',
    'Sector 45',
    'Sector 56',
    'Sohna Road',
    'Golf Course Road',
    'MG Road',
    'Udyog Vihar',
    'Palam Vihar',
  ],
};

class _SkillsStep extends ConsumerStatefulWidget {
  const _SkillsStep();

  @override
  ConsumerState<_SkillsStep> createState() => _SkillsStepState();
}

class _SkillsStepState extends ConsumerState<_SkillsStep> {
  String _experience = 'Beginner';
  int _radius = 3;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workerControllerProvider);
    final app = state.application;

    return _StepScaffold(
      icon: Icons.handyman_outlined,
      title: _copy(ref, 'Choose worker type', 'वर्कर प्रकार चुनें'),
      message: _copy(
        ref,
        'Helpers can start with general assistance work. Experience is only needed for professional skilled categories.',
        'हेल्पर सामान्य सहायता का काम शुरू कर सकते हैं। अनुभव केवल प्रोफेशनल स्किल कैटेगरी के लिए चाहिए।',
      ),
      children: [
        _EnrollmentTypeCard(
          title: _copy(ref, 'Helper', 'हेल्पर'),
          subtitle: _copy(
            ref,
            'General help such as cleaning support, washing, lifting goods, queue standing and basic assistance. No previous experience required.',
            'सफाई सहायता, धुलाई, सामान उठाना, लाइन में खड़ा होना और सामान्य मदद। पिछले अनुभव की जरूरत नहीं।',
          ),
          icon: Icons.volunteer_activism_outlined,
          selected: app.enrolledAsHelper,
          onTap: () {
            ref
                .read(workerControllerProvider.notifier)
                .toggleEnrollmentType(WorkerEnrollmentType.helper);
          },
        ),
        _EnrollmentTypeCard(
          title: _copy(ref, 'Professional', 'प्रोफेशनल'),
          subtitle: _copy(
            ref,
            'Skilled work such as electrician, driver, plumber, mechanic, barber and more.',
            'इलेक्ट्रीशियन, ड्राइवर, प्लंबर, मैकेनिक, बार्बर जैसे स्किल्ड काम।',
          ),
          icon: Icons.engineering_outlined,
          selected: app.enrolledAsProfessional,
          onTap: () {
            ref
                .read(workerControllerProvider.notifier)
                .toggleEnrollmentType(WorkerEnrollmentType.professional);
          },
        ),
        if (app.enrolledAsProfessional)
          _ProfessionalCategoryPicker(
            selectedCategories: app.professionalCategories,
          ),
        if (app.enrolledAsHelper && !app.enrolledAsProfessional)
          _HelpStrip(
            text: _copy(
              ref,
          'Helper work does not require past experience. Workida will verify your ID, area and availability before sending jobs.',
              'हेल्पर काम के लिए अनुभव जरूरी नहीं है। जॉब भेजने से पहले Gofer आपकी ID, क्षेत्र और उपलब्धता सत्यापित करेगा।',
            ),
          ),
        if (app.enrolledAsProfessional) ...[
          const SizedBox(height: 10),
          Text(
            _copy(ref, 'Professional experience', 'प्रोफेशनल अनुभव'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            _copy(
              ref,
              'This applies only to the skilled categories you selected above.',
              'यह केवल ऊपर चुनी गई स्किल्ड कैटेगरी पर लागू होता है।',
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'New Professional', label: Text('New')),
              ButtonSegment(value: '1+ Year', label: Text('1 yr')),
              ButtonSegment(value: '2+ Years', label: Text('2+ yr')),
            ],
            selected: {_experience},
            onSelectionChanged: (value) {
              setState(() => _experience = value.first);
            },
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                _copy(ref, 'Travel distance', 'यात्रा दूरी'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('$_radius km'),
          ],
        ),
        Slider(
          min: 1,
          max: 10,
          divisions: 9,
          value: _radius.toDouble(),
          label: '$_radius km',
          onChanged: (value) => setState(() => _radius = value.round()),
        ),
        FilledButton(
          onPressed: app.hasRequiredWorkSelection ? _continue : null,
          child: Text(_copy(ref, 'Continue', 'जारी रखें')),
        ),
      ],
    );
  }

  void _continue() {
    final controller = ref.read(workerControllerProvider.notifier);
    final app = ref.read(workerControllerProvider).application;
    controller.updateWorkPreferences(
      experience:
          app.enrolledAsProfessional ? _experience : 'Not required for helper',
      travelRadiusKm: _radius,
    );
    controller.goToConsent();
  }
}

class _EnrollmentTypeCard extends StatelessWidget {
  const _EnrollmentTypeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor:
                    selected ? theme.colorScheme.primary : Colors.black12,
                child:
                    Icon(icon, color: selected ? Colors.white : Colors.black54),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(subtitle),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? theme.colorScheme.primary : Colors.black38,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfessionalCategoryPicker extends ConsumerWidget {
  const _ProfessionalCategoryPicker({required this.selectedCategories});

  final Set<String> selectedCategories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(workerControllerProvider.notifier);
    final availableCategories = professionalCategories
        .where((category) => !selectedCategories.contains(category))
        .toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _copy(ref, 'Professional categories', 'प्रोफेशनल कैटेगरी'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              _copy(
                ref,
                'Search and add the skilled work you can do. You can select more than one.',
                'आप जो स्किल्ड काम कर सकते हैं उसे खोजकर जोड़ें। आप एक से ज्यादा चुन सकते हैं।',
              ),
            ),
            const SizedBox(height: 12),
            DropdownMenu<String>(
              enableFilter: true,
              requestFocusOnTap: true,
              hintText: _copy(ref, 'Search profession', 'प्रोफेशन खोजें'),
              leadingIcon: const Icon(Icons.search),
              dropdownMenuEntries: availableCategories
                  .map(
                    (category) => DropdownMenuEntry<String>(
                      value: category,
                      label: category,
                      leadingIcon: Icon(_skillIcon(category)),
                    ),
                  )
                  .toList(),
              onSelected: (category) {
                if (category == null) return;
                controller.addProfessionalCategory(category);
              },
            ),
            if (selectedCategories.isEmpty) ...[
              const SizedBox(height: 12),
              _HelpStrip(
                text: _copy(
                  ref,
                  'Professional workers must choose at least one skill category.',
                  'प्रोफेशनल वर्कर को कम से कम एक स्किल कैटेगरी चुननी होगी।',
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: selectedCategories
                    .map(
                      (category) => InputChip(
                        avatar: Icon(_skillIcon(category), size: 18),
                        label: Text(category),
                        onDeleted: () {
                          controller.removeProfessionalCategory(category);
                        },
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocumentsStep extends ConsumerStatefulWidget {
  const _DocumentsStep();

  @override
  ConsumerState<_DocumentsStep> createState() => _DocumentsStepState();
}

class _DocumentsStepState extends ConsumerState<_DocumentsStep> {
  bool _showIdTypeError = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workerControllerProvider);
    final app = state.application;
    final controller = ref.read(workerControllerProvider.notifier);
    final showIdTypeError = _showIdTypeError && app.idType == null;

    return _StepScaffold(
      icon: Icons.verified_user_outlined,
      title: _copy(ref, 'Verify your ID', 'अपनी ID सत्यापित करें'),
      message: _copy(
        ref,
        'Choose the Indian ID you are uploading. Each photo is checked before it is accepted.',
        'जो भारतीय ID आप अपलोड कर रहे हैं उसे चुनें। हर फोटो स्वीकार करने से पहले जांची जाएगी।',
      ),
      children: [
        DropdownMenu<IndianIdType>(
          width: double.infinity,
          initialSelection: app.idType,
          label: Text(_copy(ref, 'Accepted Indian ID', 'स्वीकार्य भारतीय ID')),
          leadingIcon: const Icon(Icons.badge_outlined),
          dropdownMenuEntries: IndianIdType.values
              .map(
                (type) => DropdownMenuEntry<IndianIdType>(
                  value: type,
                  label: type.label,
                ),
              )
              .toList(),
          onSelected: (type) {
            if (type == null) return;
            setState(() => _showIdTypeError = false);
            controller.selectIdType(type);
          },
        ),
        if (showIdTypeError)
          _FieldErrorText(
            text: _copy(
              ref,
              'Select which national ID you are uploading before adding front/back photos.',
              'फ्रंट/बैक फोटो जोड़ने से पहले चुनें कि आप कौन सी राष्ट्रीय ID अपलोड कर रहे हैं।',
            ),
          ),
        _HelpStrip(
          text: _copy(
            ref,
            'Accepted IDs: Aadhaar, Driving Licence, Voter ID, PAN Card and Passport. Upload original, uncropped, readable photos.',
            'स्वीकार्य ID: आधार, ड्राइविंग लाइसेंस, वोटर ID, PAN कार्ड और पासपोर्ट। मूल, पढ़ने योग्य फोटो अपलोड करें।',
          ),
        ),
        _DocumentTile(
          type: WorkerDocumentType.nationalIdFront,
          title: app.idType == null
              ? _copy(ref, 'National ID front', 'राष्ट्रीय ID फ्रंट')
              : '${app.idType!.label} front',
          subtitle: _copy(
              ref, 'Photo side of your ID card', 'ID कार्ड का फोटो वाला भाग'),
          idType: app.idType,
          onMissingIdType: _showMissingIdTypeError,
          document: app.documents[WorkerDocumentType.nationalIdFront],
        ),
        _DocumentTile(
          type: WorkerDocumentType.nationalIdBack,
          title: app.idType == null
              ? _copy(ref, 'National ID back', 'राष्ट्रीय ID बैक')
              : '${app.idType!.label} back',
          subtitle: _copy(ref, 'Address or back side of ID card',
              'ID कार्ड का पता या पीछे वाला भाग'),
          idType: app.idType,
          onMissingIdType: _showMissingIdTypeError,
          document: app.documents[WorkerDocumentType.nationalIdBack],
        ),
        _DocumentTile(
          type: WorkerDocumentType.selfie,
          title: _copy(ref, 'Selfie', 'सेल्फी'),
          subtitle: _copy(ref, 'Face should be clear and bright',
              'चेहरा साफ और रोशनी में दिखना चाहिए'),
          idType: app.idType,
          onMissingIdType: _showMissingIdTypeError,
          document: app.documents[WorkerDocumentType.selfie],
        ),
        if (!app.canSubmit)
          _FieldErrorText(text: _missingSubmitRequirement(app)),
        if (!app.consentAccepted)
          OutlinedButton.icon(
            onPressed: controller.goToConsent,
            icon: const Icon(Icons.policy_outlined),
            label: const Text('Review consent'),
          ),
        FilledButton(
          onPressed: app.canSubmit && !state.submittingEnrollment
              ? () async {
                  final error = await controller.submitForReview();
                  if (error != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(error)),
                    );
                  }
                }
              : null,
          child: state.submittingEnrollment
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(_copy(ref, 'Submitting...', 'सबमिट हो रहा है...')),
                  ],
                )
              : Text(
                  _copy(ref, 'Submit for review', 'समीक्षा के लिए सबमिट करें')),
        ),
      ],
    );
  }

  void _showMissingIdTypeError() {
    setState(() => _showIdTypeError = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _copy(
            ref,
            'Please select Aadhaar, Driving Licence, Voter ID, PAN Card or Passport first.',
            'कृपया पहले आधार, ड्राइविंग लाइसेंस, वोटर ID, PAN कार्ड या पासपोर्ट चुनें।',
          ),
        ),
      ),
    );
  }

  String _missingSubmitRequirement(WorkerApplication app) {
    if (!app.consentAccepted) {
      return 'Please accept verification consent before uploading documents.';
    }
    if (app.idType == null) {
      return 'Please select the ID type you are uploading.';
    }
    if (!app.documents.containsKey(WorkerDocumentType.nationalIdFront)) {
      return 'Please upload the front side of your ID.';
    }
    if (!app.documents.containsKey(WorkerDocumentType.nationalIdBack)) {
      return 'Please upload the back side of your ID.';
    }
    if (!app.documents.containsKey(WorkerDocumentType.selfie)) {
      return 'Please upload a clear selfie.';
    }
    return 'Please complete your profile and worker type before submitting.';
  }
}

class _DocumentTile extends ConsumerStatefulWidget {
  const _DocumentTile({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.idType,
    required this.onMissingIdType,
    required this.document,
  });

  final WorkerDocumentType type;
  final String title;
  final String subtitle;
  final IndianIdType? idType;
  final VoidCallback onMissingIdType;
  final WorkerDocument? document;

  @override
  ConsumerState<_DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends ConsumerState<_DocumentTile> {
  final _extractionService = WorkerDocumentExtractionService();
  Map<String, String> _latestExtractedFields = const <String, String>{};
  List<DocumentValidationCheck> _latestChecks =
      const <DocumentValidationCheck>[];
  bool _validating = false;

  @override
  Widget build(BuildContext context) {
    final uploaded = widget.document != null;
    final checks = uploaded ? widget.document!.validationChecks : _latestChecks;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Icon(
                      uploaded ? Icons.check : Icons.photo_camera_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        uploaded
                            ? _copy(
                                ref,
                                'Cropped, validated and uploaded',
                                'क्रॉप, जांच और अपलोड हो गया',
                              )
                            : widget.subtitle,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _validating
                            ? null
                            : widget.type == WorkerDocumentType.selfie
                                ? _captureSelfie
                                : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(
                      widget.type == WorkerDocumentType.selfie
                          ? _copy(ref, 'Start selfie check', 'सेल्फी जांच शुरू करें')
                          : _copy(ref, 'Camera', 'कैमरा'),
                    ),
                  ),
                ),
                if (widget.type != WorkerDocumentType.selfie) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _validating ? null : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(_copy(ref, 'Gallery', 'गैलरी')),
                    ),
                  ),
                ],
              ],
            ),
            if (_validating) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (checks.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ValidationChecklist(checks: checks),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _captureSelfie() async {
    setState(() {
      _validating = true;
      _latestChecks = const <DocumentValidationCheck>[];
    });
    try {
      final result = await Navigator.of(context).push<WorkerLivenessResult>(
        MaterialPageRoute(builder: (_) => const WorkerLivenessCapture()),
      );
      if (result == null || !mounted) return;
      final bytes = await result.photo.readAsBytes();
      if (!mounted) return;
      ref.read(workerControllerProvider.notifier).saveDocument(
            widget.type,
            result.photo.path,
            fileName: result.photo.name,
            contentType: 'image/jpeg',
            contentBase64: base64Encode(bytes),
            validationChecks: result.checks,
          );
      setState(() => _latestChecks = result.checks);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_copy(ref, 'Liveness selfie passed.', 'सेल्फी जांच सफल हुई।'))),
      );
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  Future<void> _pick(ImageSource source) async {
    try {
      _latestExtractedFields = const <String, String>{};
      if (widget.type != WorkerDocumentType.selfie && widget.idType == null) {
        setState(() => _latestChecks = const <DocumentValidationCheck>[]);
        widget.onMissingIdType();
        return;
      }

      final image = await ImagePicker().pickImage(
        source: source,
        imageQuality: 82,
        maxWidth: 1400,
      );
      if (image == null) return;

      if (!mounted) return;
      final cropped = await _cropImage(context, image);
      if (cropped == null) return;

      setState(() => _validating = true);
      final checks = await _validatePickedImage(
        name: _fileNameForValidation(cropped, image),
        bytes: await cropped.readAsBytes(),
      );
      if (widget.type != WorkerDocumentType.selfie &&
          checks.every((check) => check.passed)) {
        final extraction = await _extractionService.validate(
          path: cropped.path,
          idType: widget.idType!,
          documentType: widget.type,
        );
        checks.addAll(extraction.checks);
        _latestExtractedFields = extraction.extractedFields;
      }
      if (!mounted) return;
      setState(() {
        _validating = false;
        _latestChecks = checks;
      });

      final passed = checks.every((check) => check.passed);
      if (!passed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _copy(
                ref,
                'Please crop or retake the photo to fix red checks.',
                'लाल जांच ठीक करने के लिए फोटो क्रॉप करें या दोबारा लें।',
              ),
            ),
          ),
        );
        return;
      }

      ref.read(workerControllerProvider.notifier).saveDocument(
            widget.type,
            cropped.path,
            fileName: _fileNameForValidation(cropped, image),
            contentType:
                _contentTypeForFile(_fileNameForValidation(cropped, image)),
            contentBase64: base64Encode(await cropped.readAsBytes()),
            validationChecks: checks,
            extractedFields: _latestExtractedFields,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_successMessage)),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _copy(
              ref,
              'Could not open camera or gallery.',
              'कैमरा या गैलरी नहीं खुल सकी।',
            ),
          ),
        ),
      );
    }
  }

  Future<CroppedFile?> _cropImage(BuildContext context, XFile image) {
    return ImageCropper().cropImage(
      sourcePath: image.path,
      compressQuality: 92,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: widget.type == WorkerDocumentType.selfie
              ? 'Crop selfie'
              : 'Crop ${widget.idType?.label ?? 'ID'}',
          toolbarColor: Theme.of(context).colorScheme.primary,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: widget.type == WorkerDocumentType.selfie
              ? CropAspectRatioPreset.square
              : CropAspectRatioPreset.ratio16x9,
          lockAspectRatio: false,
        ),
        IOSUiSettings(
          title: widget.type == WorkerDocumentType.selfie
              ? 'Crop selfie'
              : 'Crop ${widget.idType?.label ?? 'ID'}',
        ),
        WebUiSettings(
          context: context,
          size: const CropperSize(width: 520, height: 520),
          presentStyle: WebPresentStyle.dialog,
        ),
      ],
    );
  }

  Future<List<DocumentValidationCheck>> _validatePickedImage({
    required String name,
    required Uint8List bytes,
  }) async {
    final checks = <DocumentValidationCheck>[];

    final extension = name.split('.').last.toLowerCase();
    const allowedExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif'};
    checks.add(
      DocumentValidationCheck(
        label: 'Supported photo format',
        passed: allowedExtensions.contains(extension),
        message: allowedExtensions.contains(extension)
            ? 'JPG, PNG or HEIC photo detected.'
            : 'Upload JPG, PNG or HEIC.',
      ),
    );

    final minBytes =
        widget.type == WorkerDocumentType.selfie ? 60 * 1024 : 90 * 1024;
    checks.add(
      DocumentValidationCheck(
        label: 'Enough image detail',
        passed: bytes.length >= minBytes,
        message: bytes.length >= minBytes
            ? 'File has enough detail for review.'
            : 'Photo is too small. Retake closer and brighter.',
      ),
    );

    final imageInfo = await _decodeImage(bytes);
    checks.add(
      DocumentValidationCheck(
        label: 'Readable image file',
        passed: imageInfo != null,
        message: imageInfo == null
            ? 'This file could not be read as an image.'
            : 'Image opened successfully.',
      ),
    );

    if (imageInfo == null) {
      return checks;
    }

    final minWidth = widget.type == WorkerDocumentType.selfie ? 480 : 720;
    final minHeight = widget.type == WorkerDocumentType.selfie ? 480 : 440;
    final resolutionPassed =
        imageInfo.width >= minWidth && imageInfo.height >= minHeight;
    checks.add(
      DocumentValidationCheck(
        label: 'Clear resolution',
        passed: resolutionPassed,
        message: resolutionPassed
            ? '${imageInfo.width.round()} x ${imageInfo.height.round()} px is clear enough.'
            : 'Needs at least $minWidth x $minHeight px after crop.',
      ),
    );

    if (widget.type != WorkerDocumentType.selfie) {
      final ratio = imageInfo.width / imageInfo.height;
      final framingPassed = ratio >= 1.05 && ratio <= 2.7;
      checks.add(
        DocumentValidationCheck(
          label: 'Document framing',
          passed: framingPassed,
          message: framingPassed
              ? 'Crop looks like a full ID/document area.'
              : 'Crop closer to the rectangular card/document, with less background.',
        ),
      );
    } else {
      final ratio = imageInfo.width / imageInfo.height;
      final framingPassed = ratio >= 0.65 && ratio <= 1.55;
      checks.add(
        DocumentValidationCheck(
          label: 'Face framing',
          passed: framingPassed,
          message: framingPassed
              ? 'Selfie crop is suitable.'
              : 'Crop around your face and shoulders.',
        ),
      );
    }

    checks.add(
      const DocumentValidationCheck(
        label: 'Manual review ready',
        passed: true,
        message:
            'Final authenticity check will still be done during Workida verification.',
      ),
    );

    return checks;
  }

  Future<Size?> _decodeImage(Uint8List bytes) async {
    try {
      final descriptor = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      return size;
    } catch (_) {
      try {
        final image = await decodeImageFromList(bytes);
        return Size(image.width.toDouble(), image.height.toDouble());
      } catch (_) {
        return null;
      }
    }
  }

  String _fileNameForValidation(CroppedFile cropped, XFile original) {
    final croppedName = cropped.path.split(RegExp(r'[\\/]')).last;
    if (croppedName.contains('.')) return croppedName;
    return original.name;
  }

  String _contentTypeForFile(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      _ => 'image/jpeg',
    };
  }

  String get _successMessage {
    if (widget.type == WorkerDocumentType.selfie) {
      return _copy(ref, 'Selfie looks clear and was uploaded.',
          'सेल्फी साफ है और अपलोड हो गई।');
    }
    return _copy(
      ref,
      '${widget.idType?.label ?? 'ID'} photo passed the clarity check.',
      '${widget.idType?.label ?? 'ID'} फोटो क्लैरिटी जांच में पास हो गई।',
    );
  }
}

class _ValidationChecklist extends StatelessWidget {
  const _ValidationChecklist({required this.checks});

  final List<DocumentValidationCheck> checks;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: checks
            .map(
              (check) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      check.passed ? Icons.check_circle : Icons.cancel_outlined,
                      size: 20,
                      color: check.passed
                          ? const Color(0xFF0F766E)
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            check.label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            check.message,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _FieldErrorText extends StatelessWidget {
  const _FieldErrorText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentStep extends ConsumerWidget {
  const _ConsentStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);
    final app = state.application;
    final controller = ref.read(workerControllerProvider.notifier);

    return _StepScaffold(
      icon: Icons.policy_outlined,
      title: _copy(ref, 'Allow verification', 'सत्यापन की अनुमति दें'),
      message: _copy(
        ref,
        'Workida will check your ID, selfie, worker type, professional categories, and background before approval.',
        'मंजूरी से पहले Gofer आपकी ID, सेल्फी, वर्कर प्रकार, प्रोफेशनल कैटेगरी और बैकग्राउंड जांचेगा।',
      ),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _ConsentLine(
                  text: _copy(
                      ref, 'My details are correct.', 'मेरी जानकारी सही है।'),
                ),
                _ConsentLine(
                  text: _copy(
                    ref,
                    'Workida can verify my ID and background.',
                    'Gofer मेरी ID और बैकग्राउंड सत्यापित कर सकता है।',
                  ),
                ),
                _ConsentLine(
                  text: _copy(
                    ref,
                    'I will follow customer safety rules.',
                    'मैं ग्राहक सुरक्षा नियमों का पालन करूंगा।',
                  ),
                ),
              ],
            ),
          ),
        ),
        CheckboxListTile(
          value: app.consentAccepted,
          onChanged: state.submittingEnrollment
              ? null
              : (value) => controller.setConsentAccepted(value ?? false),
          title: Text(
            _copy(ref, 'I agree and want to submit',
                'मैं सहमत हूं और सबमिट करना चाहता हूं'),
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        if (state.enrollmentError != null)
          _FieldErrorText(text: state.enrollmentError!),
        FilledButton.icon(
          onPressed: app.consentAccepted && !state.submittingEnrollment
              ? controller.goToDocuments
              : null,
          icon: const Icon(Icons.upload_file_outlined),
          label:
              Text(_copy(ref, 'Continue to documents', 'दस्तावेजों पर जाएं')),
        ),
      ],
    );
  }
}

class WorkerReviewScreen extends ConsumerWidget {
  const WorkerReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(workerControllerProvider).application;
    final hindi = _isHindi(ref);

    return WorkerVoiceGuide(
      prompt: _workerReviewPrompt,
      enabled: _isHindi(ref),
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 22),
              Icon(
                Icons.hourglass_top,
                size: 54,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              Text(
                hindi ? 'सत्यापन समीक्षा में है' : 'Verification in review',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                hindi
                    ? 'आपकी प्रोफाइल सबमिट हो गई है। जॉब मिलने से पहले Gofer एडमिन आपकी ID, सेल्फी, वर्कर प्रकार, प्रोफेशनल कैटेगरी और बैकग्राउंड जांचेगा।'
                    : 'Your profile is submitted. Workida admin will check your ID, selfie, worker type, professional categories, and background before you can receive jobs.',
              ),
              const SizedBox(height: 18),
              _ReviewStatusCard(app: app),
              const SizedBox(height: 18),
              _HelpStrip(
                text: hindi
                    ? 'अगर कोई फोटो साफ नहीं है, तो आपको उसे फिर से अपलोड करने के लिए कहा जाएगा।'
                    : 'If a photo is unclear, you will be asked to upload it again.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WorkerShell extends ConsumerStatefulWidget {
  const WorkerShell({super.key});

  @override
  ConsumerState<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends ConsumerState<WorkerShell>
    with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(workerControllerProvider.notifier).refreshPresenceOnResume();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // The system notification channel owns background alerting. Do not
      // leave the foreground-only looping ringtone attached to an activity
      // that is no longer visible.
      unawaited(WorkerDispatchService.instance.stopAlert());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workerControllerProvider);
    final hasOffer = state.currentJob?.status == WorkerJobStatus.offered;
    final pages = [
      const WorkerHomePage(),
      const WorkerJobsPage(),
      const WorkerEarningsPage(),
      const WorkerProfilePage(),
    ];

    return Scaffold(
      body: Column(
        children: [
          if (hasOffer)
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: SafeArea(
                bottom: false,
                child: ListTile(
                  leading: const Icon(Icons.notifications_active),
                  title: const Text(
                    'New job request',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${state.currentJob!.workType} · ${state.currentJob!.payLabel}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => setState(() => _index = 1),
                ),
              ),
            ),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: hasOffer,
              child: const Icon(Icons.work_outline),
            ),
            label: 'Jobs',
          ),
          const NavigationDestination(
              icon: Icon(Icons.payments_outlined), label: 'Earnings'),
          const NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}

class WorkerHomePage extends ConsumerWidget {
  const WorkerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);
    final app = state.application;
    final controller = ref.read(workerControllerProvider.notifier);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Hi, ${app.fullName}',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          Text('${app.workArea}, ${app.city}'),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.updatingAvailability
                              ? 'Confirming availability...'
                              : state.online
                                  ? 'You are online'
                                  : 'You are offline',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.updatingAvailability
                              ? 'Checking permissions, location and notifications.'
                              : state.online
                                  ? state.currentJob != null
                                      ? 'Finish or cancel your active job before going offline.'
                                      : 'Your location and job notifications are active.'
                                  : 'Go online when you are ready for work.',
                        ),
                      ],
                    ),
                  ),
                  if (state.updatingAvailability)
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  else
                    Switch(
                      value: state.online,
                      onChanged: (value) async {
                        await controller.setOnline(value);
                      },
                    ),
                ],
              ),
            ),
          ),
          if (state.availabilityError != null) ...[
            const SizedBox(height: 10),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.notifications_off_outlined,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            state.availabilityError!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (state.availabilityRequiresSettings) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: controller.openAvailabilitySettings,
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('Open app settings'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (state.currentJob != null) ...[
            Text(
              state.currentJob!.status == WorkerJobStatus.offered
                  ? 'New job request'
                  : 'Current job',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            _WorkerJobCard(job: state.currentJob!),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  title: 'Today',
                  value: 'Rs ${state.earningsToday}',
                  icon: Icons.currency_rupee,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  title: 'Jobs',
                  value: '${state.completedJobs}',
                  icon: Icons.done_all_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: state.online && state.currentJob == null
                ? controller.checkForPendingJob
                : null,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh job requests'),
          ),
          const SizedBox(height: 14),
          const _UrgentAlertsCard(),
          const SizedBox(height: 14),
          const _HelpStrip(
            text:
                'Keep Workida Worker online to receive nearby customer requests.',
          ),
        ],
      ),
    );
  }
}

class WorkerJobsPage extends ConsumerWidget {
  const WorkerJobsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);
    final job = state.currentJob;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Jobs', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          if (job == null)
            const _EmptyWorkerPanel(
              icon: Icons.work_outline,
              title: 'No job right now',
              message:
                  'Go online and nearby customer requests will appear here.',
            )
          else
            _WorkerJobCard(job: job),
          if (state.jobHistory.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Completed jobs',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            ...state.jobHistory.map(_WorkerHistoryTile.new),
          ],
        ],
      ),
    );
  }
}

class _WorkerJobCard extends ConsumerWidget {
  const _WorkerJobCard({required this.job});

  final WorkerJobRequest job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);
    final controller = ref.read(workerControllerProvider.notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Icon(_skillIcon(job.workType))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(job.workType,
                          style: Theme.of(context).textTheme.titleLarge),
                      Text('${job.distanceKm} km away - ${job.durationLabel}'),
                    ],
                  ),
                ),
                Text(job.payLabel,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 14),
            _InfoRow(icon: Icons.location_on_outlined, text: job.customerArea),
            _InfoRow(icon: Icons.notes_outlined, text: job.notes),
            if (job.status == WorkerJobStatus.offered && job.expiresAt != null)
              _OfferCountdown(expiresAt: job.expiresAt!),
            if (state.jobActionError != null) ...[
              const SizedBox(height: 8),
              Text(
                state.jobActionError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 16),
            switch (job.status) {
              WorkerJobStatus.offered => Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: state.jobActionInProgress
                            ? null
                            : controller.rejectJob,
                        child: const Text('Reject'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: state.jobActionInProgress
                            ? null
                            : controller.acceptJob,
                        child: state.jobActionInProgress
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              WorkerJobStatus.accepted => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: state.jobActionInProgress
                          ? null
                          : controller.markArrived,
                      icon: const Icon(Icons.near_me_outlined),
                      label: const Text('Mark arrived'),
                    ),
                    TextButton.icon(
                      onPressed: state.jobActionInProgress
                          ? null
                          : () => _confirmCancellation(context, controller),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel job'),
                    ),
                  ],
                ),
              WorkerJobStatus.arrived => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: state.jobActionInProgress
                          ? null
                          : controller.startWork,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start work'),
                    ),
                    TextButton.icon(
                      onPressed: state.jobActionInProgress
                          ? null
                          : () => _confirmCancellation(context, controller),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel job'),
                    ),
                  ],
                ),
              WorkerJobStatus.started => FilledButton.icon(
                  onPressed: state.jobActionInProgress
                      ? null
                      : () => _confirmCompletion(context, controller),
                  icon: const Icon(Icons.done_all_outlined),
                  label: const Text('Request completion'),
                ),
              WorkerJobStatus.completionRequested => const Card(
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(Icons.hourglass_top_outlined),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Waiting for the customer to confirm that the work is completed.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              WorkerJobStatus.completed => const SizedBox.shrink(),
            },
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancellation(
    BuildContext context,
    WorkerController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this job?'),
        content: const Text(
          'This will release your assignment. Workida will immediately search for a replacement worker for the customer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep job'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel job'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.cancelCurrentJob();
  }

  Future<void> _confirmCompletion(
    BuildContext context,
    WorkerController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Is the work completed?'),
        content: const Text(
          'The customer will be asked to inspect and confirm the completed work.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Work remaining'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request confirmation'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.completeWork();
  }
}

class _OfferCountdown extends StatefulWidget {
  const _OfferCountdown({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_OfferCountdown> createState() => _OfferCountdownState();
}

class _OfferCountdownState extends State<_OfferCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining =
        widget.expiresAt.toUtc().difference(DateTime.now().toUtc());
    final seconds = remaining.inSeconds.clamp(0, 5999);
    final label =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            Icons.timer_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text(
            seconds == 0 ? 'Offer expired' : 'Respond within $label',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _UrgentAlertsCard extends StatefulWidget {
  const _UrgentAlertsCard();

  @override
  State<_UrgentAlertsCard> createState() => _UrgentAlertsCardState();
}

class _UrgentAlertsCardState extends State<_UrgentAlertsCard>
    with WidgetsBindingObserver {
  WorkerAlertSettings? _settings;
  bool _loading = true;

  bool get _supportsUrgentAlerts =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (!_supportsUrgentAlerts) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final settings = await WorkerDispatchService.instance.alertSettings();
      if (mounted) {
        setState(() {
          _settings = settings;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsUrgentAlerts) return const SizedBox.shrink();
    final enabled = _settings?.urgentSoundEnabled == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(enabled
                    ? Icons.notifications_active
                    : Icons.notification_important_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Urgent job alert sound',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    enabled ? Icons.check_circle : Icons.warning_amber,
                    color: enabled
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              enabled
                  ? 'Job requests may sound while the phone is muted or in Do Not Disturb.'
                  : 'Allow Do Not Disturb access and keep the Job requests notification channel enabled.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_settings?.notificationPolicyAccess != true)
                  FilledButton.tonalIcon(
                    onPressed:
                        WorkerDispatchService.instance.requestUrgentAlertAccess,
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('Allow urgent sound'),
                  ),
                OutlinedButton.icon(
                  onPressed: WorkerDispatchService
                      .instance.openJobNotificationSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Notification settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class WorkerEarningsPage extends ConsumerWidget {
  const WorkerEarningsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerControllerProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Earnings', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          _MetricCard(
            title: 'Today earnings',
            value: 'Rs ${state.earningsToday}',
            icon: Icons.currency_rupee,
          ),
          const SizedBox(height: 12),
          _MetricCard(
            title: 'Completed jobs',
            value: '${state.completedJobs}',
            icon: Icons.task_alt_outlined,
          ),
          const SizedBox(height: 18),
          _MetricCard(
            title: 'Lifetime earnings',
            value: 'Rs ${state.totalEarnings}',
            icon: Icons.account_balance_wallet_outlined,
          ),
          const SizedBox(height: 22),
          Text(
            'Earnings history',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          if (state.jobHistory.isEmpty)
            const _EmptyWorkerPanel(
              icon: Icons.receipt_long_outlined,
              title: 'No completed jobs yet',
              message: 'Completed work and earnings will appear here.',
            )
          else
            ...state.jobHistory.map(_WorkerHistoryTile.new),
        ],
      ),
    );
  }
}

class _WorkerHistoryTile extends StatelessWidget {
  const _WorkerHistoryTile(this.item);

  final WorkerJobHistoryItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.task_alt)),
        title: Text(
          item.workType,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${item.customerArea}\n${DateFormat('d MMM yyyy, h:mm a').format(item.completedAt)}',
        ),
        isThreeLine: true,
        trailing: Text(
          'Rs ${item.amount}',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class WorkerProfilePage extends ConsumerWidget {
  const WorkerProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(workerControllerProvider).application;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Profile', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.fullName,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text('+91 ${app.phone}'),
                  Text('${app.workArea}, ${app.city}'),
                  const Divider(height: 28),
                  const _InfoRow(
                      icon: Icons.verified_user_outlined,
                      text: 'Status: Approved'),
                  _InfoRow(
                    icon: Icons.handyman_outlined,
                    text: _serviceSummary(app),
                  ),
                  if (app.idType != null)
                    _InfoRow(
                      icon: Icons.badge_outlined,
                      text: 'ID type: ${app.idType!.label}',
                    ),
                  if (app.enrolledAsProfessional)
                    _InfoRow(
                      icon: Icons.workspace_premium_outlined,
                      text: 'Professional experience: ${app.experience}',
                    ),
                  _InfoRow(
                    icon: Icons.social_distance_outlined,
                    text: '${app.travelRadiusKm} km travel radius',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      ref
                          .read(workerControllerProvider.notifier)
                          .clearSession();
                    },
                    icon: const Icon(Icons.logout_outlined),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.icon,
    required this.title,
    required this.message,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(message),
        const SizedBox(height: 18),
        ...children.expand((child) => [child, const SizedBox(height: 12)]),
      ],
    );
  }
}

class _BigChoice extends StatelessWidget {
  const _BigChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              CircleAvatar(child: Icon(icon)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(subtitle),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
      ),
    );
  }
}

class _ConsentLine extends StatelessWidget {
  const _ConsentLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(Icons.check_circle,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ReviewStatusCard extends StatelessWidget {
  const _ReviewStatusCard({required this.app});

  final WorkerApplication app;

  @override
  Widget build(BuildContext context) {
    final items = [
      const _InfoRow(
          icon: Icons.phone_android_outlined, text: 'Phone verified'),
      const _InfoRow(
          icon: Icons.badge_outlined, text: 'Profile details submitted'),
      _InfoRow(
        icon: Icons.photo_camera_outlined,
        text: app.idType == null
            ? 'ID and selfie uploaded'
            : '${app.idType!.label} and selfie uploaded',
      ),
      _InfoRow(icon: Icons.work_outline, text: _serviceSummary(app)),
      if (app.enrolledAsProfessional)
        _InfoRow(
          icon: Icons.workspace_premium_outlined,
          text: 'Professional experience: ${app.experience}',
        ),
      const _InfoRow(
          icon: Icons.manage_search_outlined, text: 'Admin review pending'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: items),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            Text(title),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _HelpStrip extends StatelessWidget {
  const _HelpStrip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _EmptyWorkerPanel extends StatelessWidget {
  const _EmptyWorkerPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

String _serviceSummary(WorkerApplication app) {
  final parts = <String>[];
  if (app.enrolledAsHelper) {
    parts.add('Helper');
  }
  if (app.enrolledAsProfessional) {
    final categories = app.professionalCategories.isEmpty
        ? 'Professional'
        : 'Professional: ${app.professionalCategories.join(', ')}';
    parts.add(categories);
  }
  return parts.isEmpty ? 'No worker type selected' : parts.join(' + ');
}

IconData _skillIcon(String skill) {
  return switch (skill) {
    'Helper work' => Icons.volunteer_activism_outlined,
    'Cleaning' => Icons.cleaning_services_outlined,
    'Packing' => Icons.inventory_2_outlined,
    'Household Help' => Icons.home_repair_service_outlined,
    'Moving Items' => Icons.local_shipping_outlined,
    'Heavy Lifting' => Icons.fitness_center_outlined,
    'Gardening' => Icons.yard_outlined,
    'AC Technician' => Icons.ac_unit_outlined,
    'Appliance Repair Technician' => Icons.build_outlined,
    'Auto Mechanic' => Icons.car_repair_outlined,
    'Electrician' => Icons.electrical_services_outlined,
    'Plumber' => Icons.plumbing_outlined,
    'Barber' => Icons.content_cut,
    'Beautician' => Icons.spa_outlined,
    'Car Driver' => Icons.directions_car_outlined,
    'Driver' => Icons.drive_eta_outlined,
    'Delivery Rider' => Icons.delivery_dining_outlined,
    'Painter' => Icons.format_paint_outlined,
    'Carpenter' => Icons.carpenter_outlined,
    'Chef' => Icons.restaurant_outlined,
    'Cook' => Icons.soup_kitchen_outlined,
    'Home Nurse' => Icons.medical_services_outlined,
    'Security Guard' => Icons.security_outlined,
    'Tailor' => Icons.checkroom_outlined,
    'Photographer' => Icons.photo_camera_outlined,
    'Videographer' => Icons.videocam_outlined,
    'Welder' => Icons.hardware_outlined,
    _ => Icons.handyman_outlined,
  };
}
