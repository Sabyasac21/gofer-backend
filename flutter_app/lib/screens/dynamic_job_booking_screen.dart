import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../data/sample_data.dart';
import '../domain/service_catalog.dart';
import '../domain/service_expectation.dart';
import '../domain/pricing_engine.dart';
import '../domain/booking_schedule.dart';
import '../models/taskr_models.dart';
import '../providers/booking_provider.dart';
import '../providers/customer_location_provider.dart';
import '../services/customer_location_service.dart';
import '../services/customer_api_service.dart';
import 'customer_phone_verification_screen.dart';
import '../widgets/service_expectation_card.dart';
import '../widgets/service_location_picker.dart';
import '../widgets/booking_countdown_label.dart';

class DynamicJobBookingScreen extends ConsumerStatefulWidget {
  const DynamicJobBookingScreen({
    super.key,
    required this.service,
    this.initialAnswers = const {},
  });

  final ServiceDefinition service;
  final Map<String, Object> initialAnswers;

  @override
  ConsumerState<DynamicJobBookingScreen> createState() =>
      _DynamicJobBookingScreenState();
}

class _DynamicJobBookingScreenState
    extends ConsumerState<DynamicJobBookingScreen> {
  final _bookingAttemptId = const Uuid().v4();
  late ServiceLocation _serviceLocation;
  late int _estimatedMinutes;
  String? _variantId;
  int _quantity = 1;
  int _step = 0;
  TaskUrgency _urgency = TaskUrgency.now;
  DateTime? _scheduledAt;
  bool _submitting = false;
  final _pricingApi = CustomerApiService();
  ServicePricingConfig? _remotePricingConfig;
  bool _pricingLoading = false;
  int _pricingRequestId = 0;
  final Map<String, CustomerPricingQuote> _variantQuotes = {};
  int _variantPricingRequestId = 0;

  JobTemplate get _template => widget.service.template;

  ServicePricingConfig get _pricingConfig =>
      _remotePricingConfig ??
      WorkidaPricingCatalog.forService(
        widget.service,
        variantId: _variantId,
        city: WorkidaPricingCatalog.cityForAddress(_serviceLocation.address),
        quantity: _quantity,
      );

  bool get _showServiceOptions =>
      !_pricingConfig.disableVariants &&
      _pricingConfig.pricingModel != PricingModel.hourly &&
      WorkidaPricingCatalog.variantsForService(widget.service.id).isNotEmpty;

  @override
  void initState() {
    super.initState();
    _serviceLocation = ref.read(customerLocationProvider).location;
    final variants =
        WorkidaPricingCatalog.variantsForService(widget.service.id);
    _variantId = variants.isEmpty ? null : variants.first.id;
    final initialConfig = WorkidaPricingCatalog.forService(
      widget.service,
      variantId: _variantId,
      city: WorkidaPricingCatalog.cityForAddress(_serviceLocation.address),
      quantity: _quantity,
    );
    if (initialConfig.pricingModel == PricingModel.hourly) {
      _variantId = null;
    }
    _estimatedMinutes = _pricingConfig.estimatedDurationMinMinutes;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_refreshPricing());
        unawaited(_refreshVariantPricing());
      }
    });
  }

  Future<void> _refreshPricing() async {
    if (!mounted) return;
    final requestId = ++_pricingRequestId;
    setState(() => _pricingLoading = true);
    try {
      final quote = await _pricingApi.pricingQuote(
        serviceId: widget.service.id,
        serviceType: _template.workforceCategory == WorkforceCategory.helper
            ? 'helper'
            : 'professional',
        capabilityKey: widget.service.capabilityKey,
        category: _legacyCategory().name,
        variantId: _variantId,
        city: WorkidaPricingCatalog.cityForAddress(_serviceLocation.address),
        quantity: _quantity,
      );
      if (!mounted || requestId != _pricingRequestId) return;
      setState(() {
        _remotePricingConfig = quote.config;
        final selectedVariantId = _variantId;
        if (selectedVariantId != null) {
          _variantQuotes[selectedVariantId] = quote;
        }
        if (quote.config.pricingModel == PricingModel.hourly ||
            quote.config.disableVariants) {
          _variantId = null;
        }
        _estimatedMinutes = _estimatedMinutes.clamp(
          quote.config.estimatedDurationMinMinutes,
          quote.config.estimatedDurationMaxMinutes,
        );
      });
    } catch (_) {
      // The generated catalogue is a safe offline fallback. The task service
      // still recalculates the authoritative amount before saving a booking.
    } finally {
      if (mounted && requestId == _pricingRequestId) {
        setState(() => _pricingLoading = false);
      }
    }
  }

  /// Fetches a live quote for every service option so the picker shows the
  /// same authoritative prices as the estimate card below it. Without this the
  /// picker falls back to the bundled price book and can disagree with the
  /// card whenever an admin has changed a per-option price.
  Future<void> _refreshVariantPricing() async {
    if (!mounted) return;
    final variants =
        WorkidaPricingCatalog.variantsForService(widget.service.id);
    if (variants.isEmpty) return;
    final requestId = ++_variantPricingRequestId;
    final city = WorkidaPricingCatalog.cityForAddress(_serviceLocation.address);
    final serviceType = _template.workforceCategory == WorkforceCategory.helper
        ? 'helper'
        : 'professional';
    final category = _legacyCategory().name;
    final results = await Future.wait(
      variants.map((variant) async {
        try {
          final quote = await _pricingApi.pricingQuote(
            serviceId: widget.service.id,
            serviceType: serviceType,
            capabilityKey: widget.service.capabilityKey,
            category: category,
            variantId: variant.id,
            city: city,
            quantity: _quantity,
          );
          return MapEntry(variant.id, quote);
        } catch (_) {
          // The picker keeps its bundled-price fallback for this option.
          return MapEntry<String, CustomerPricingQuote?>(variant.id, null);
        }
      }),
    );
    if (!mounted || requestId != _variantPricingRequestId) return;
    setState(() {
      for (final entry in results) {
        final quote = entry.value;
        if (quote != null) _variantQuotes[entry.key] = quote;
      }
    });
  }

  PricingEstimate get _estimate => PricingEngine.calculateEstimate(
        config: _pricingConfig,
        estimatedMinutes: _estimatedMinutes,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.service.name)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    switch (_step) {
                      0 => _pricingConfig.pricingModel == PricingModel.hourly
                          ? 'Choose estimated time'
                          : 'Review service details',
                      1 => 'Where and when?',
                      _ => 'Review your booking',
                    },
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: (_step + 1) / 3),
                  const SizedBox(height: 6),
                  Text('Step ${_step + 1} of 3'),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_step == 0) _durationStep(),
                  if (_step == 1) _placeAndTimeStep(),
                  if (_step == 2) _summaryStep(),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor.withValues(alpha: .4),
                  ),
                ),
              ),
              child: Row(
                children: [
                  if (_step > 0) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _submitting ? null : () => setState(() => _step--),
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _submitting ? null : _continue,
                      child: _submitting
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_step == 2 ? 'Confirm booking' : 'Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _durationStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_template.description),
        const SizedBox(height: 16),
        ServiceExpectationCard(
          expectation: expectationForService(
            widget.service,
            included: _pricingConfig.includedScope,
            notIncluded: _pricingConfig.exclusions,
          ),
        ),
        const SizedBox(height: 20),
        if (_showServiceOptions) ...[
          _ServiceOptionPicker(
            service: widget.service,
            city: WorkidaPricingCatalog.cityForAddress(
              _serviceLocation.address,
            ),
            selectedId: _variantId,
            liveQuotes: _variantQuotes,
            onChanged: (value) {
              setState(() {
                _variantId = value;
                _remotePricingConfig = null;
                _estimatedMinutes = _pricingConfig.estimatedDurationMinMinutes;
              });
              unawaited(_refreshPricing());
            },
          ),
          const SizedBox(height: 16),
        ],
        if (_pricingConfig.pricingModel == PricingModel.perUnit) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Quantity (${_pricingConfig.unit})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: _quantity > 1
                    ? () {
                        setState(() {
                          _quantity--;
                          _remotePricingConfig = null;
                        });
                        unawaited(_refreshPricing());
                      }
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_quantity', style: Theme.of(context).textTheme.titleLarge),
              IconButton(
                onPressed: _quantity < 20
                    ? () {
                        setState(() {
                          _quantity++;
                          _remotePricingConfig = null;
                        });
                        unawaited(_refreshPricing());
                      }
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (_pricingLoading) ...[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 10),
          Text(
            'Checking the latest Workida price…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
        ],
        _DurationAndEstimateCard(
          config: _pricingConfig,
          selectedMinutes: _estimatedMinutes,
          estimate: _estimate,
          onChanged: (minutes) => setState(() => _estimatedMinutes = minutes),
        ),
      ],
    );
  }

  Widget _placeAndTimeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ServiceLocationPicker(
          location: _serviceLocation,
          onChanged: (location) {
            final oldCity = WorkidaPricingCatalog.cityForAddress(
              _serviceLocation.address,
            );
            final newCity = WorkidaPricingCatalog.cityForAddress(
              location.address,
            );
            setState(() {
              _serviceLocation = location;
              if (oldCity != newCity) {
                _remotePricingConfig = null;
                _variantQuotes.clear();
              }
            });
            if (oldCity != newCity) {
              unawaited(_refreshPricing());
              unawaited(_refreshVariantPricing());
            }
          },
        ),
        const SizedBox(height: 24),
        Text('When do you need help?',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SegmentedButton<TaskUrgency>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: TaskUrgency.now, label: Text('Now')),
            ButtonSegment(value: TaskUrgency.today, label: Text('Today')),
            ButtonSegment(value: TaskUrgency.scheduled, label: Text('Later')),
          ],
          selected: {_urgency},
          onSelectionChanged: (selection) {
            unawaited(_selectUrgency(selection.first));
          },
        ),
        if (_urgency != TaskUrgency.now) ...[
          const SizedBox(height: 12),
          _ScheduleSelectionCard(
            urgency: _urgency,
            scheduledAt: _scheduledAt,
            onTap: _pickSchedule,
          ),
        ],
        const SizedBox(height: 24),
        const _InformationCard(
          icon: Icons.inventory_2_outlined,
          title: 'Labour-only service',
          message:
              'Materials and spare parts are purchased separately by you. Workers bring their normal professional tools.',
        ),
      ],
    );
  }

  Widget _summaryStep() {
    final estimate = _estimate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BookingReviewHero(
          serviceName: _template.name,
          total: estimate.estimatedTotal.formatted,
          duration: durationLabel(_estimatedMinutes),
        ),
        const SizedBox(height: 16),
        _ReviewCard(
          title: 'Price breakdown',
          icon: Icons.receipt_long_outlined,
          child: _PricingBreakdown(
              estimate: estimate, compact: false, config: _pricingConfig),
        ),
        const SizedBox(height: 16),
        _ReviewCard(
          title: 'Booking details',
          icon: Icons.calendar_month_outlined,
          child: Column(children: [
            _ReviewDetailRow(
                icon: Icons.schedule_outlined,
                label: 'Schedule',
                value: _scheduleSummary),
            const Divider(height: 24),
            _ReviewDetailRow(
                icon: Icons.location_on_outlined,
                label: 'Service location',
                value: _serviceLocation.address),
            const Divider(height: 24),
            const _ReviewDetailRow(
                icon: Icons.inventory_2_outlined,
                label: 'Materials',
                value: 'Not included. Purchase separately if needed.'),
          ]),
        ),
        const SizedBox(height: 16),
        const _InformationCard(
          icon: Icons.fact_check_outlined,
          title: 'Approval protects you',
          message:
              'Final labour uses verified working time. Additional time or work cannot increase your bill without your approval.',
        ),
      ],
    );
  }

  Future<void> _continue() async {
    if (_step == 0) {
      setState(() => _step++);
      return;
    }
    if (_step == 1) {
      if (!_serviceLocation.verified) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add and verify the service location.'),
          ),
        );
        return;
      }
      if (!BookingSchedulePolicy.isValid(
        urgency: _urgency,
        scheduledAt: _scheduledAt,
        now: DateTime.now(),
      )) {
        _showScheduleMessage(
          _urgency == TaskUrgency.today
              ? 'Select a valid time later today.'
              : 'Select a date and time within the next three days.',
        );
        await _pickSchedule();
        return;
      }
      setState(() => _step++);
      return;
    }
    await _submit();
  }

  Future<void> _submit() async {
    if (!await _ensurePhoneVerified()) return;
    setState(() => _submitting = true);
    final estimate = _estimate;
    final category = _legacyCategory();
    final expectation = expectationForService(
      widget.service,
      included: _pricingConfig.includedScope,
      notIncluded: _pricingConfig.exclusions,
    );
    final contractualScope = <String>[
      'Customer-selected estimated time: ${durationLabel(_estimatedMinutes)}',
      'Included service scope:',
      ...expectation.included.map((item) => 'Included: $item'),
      'Service exclusions:',
      ...expectation.notIncluded.map((item) => 'Not included: $item'),
      'Expected completion: ${expectation.completionOutcome}',
    ];
    await ref.read(bookingControllerProvider.notifier).submitTask(
          category: category,
          title: _template.name,
          description: contractualScope.join('\n'),
          location: _serviceLocation.address,
          latitude: _serviceLocation.latitude,
          longitude: _serviceLocation.longitude,
          urgency: _urgency,
          scheduledAt: _scheduledAt,
          budget: estimate.estimatedTotal.wholeRupees,
          workerType: _pricingConfig.workerType == PricingWorkerType.helper
              ? WorkerType.helper
              : WorkerType.professional,
          helperCategory:
              _template.workforceCategory == WorkforceCategory.helper
                  ? widget.service.name
                  : null,
          professionalCategory:
              _template.workforceCategory == WorkforceCategory.professional
                  ? widget.service.name
                  : null,
          serviceId: widget.service.id,
          capabilityKey: widget.service.capabilityKey,
          eligibleWorkerCategories: widget.service.workerCategories,
          estimatedMinPrice: estimate.estimatedTotal.wholeRupees,
          estimatedMaxPrice: estimate.estimatedTotal.wholeRupees,
          expectedDuration: durationLabel(_estimatedMinutes),
          estimatedDurationMinutes: _estimatedMinutes,
          pricingConfig: _pricingConfig,
          notes: contractualScope.join('; '),
          workCondition:
              'Only the displayed included scope is authorised; exclusions and additional work require customer approval',
          idempotencyKey: _bookingAttemptId,
        );
    if (!mounted) return;
    setState(() => _submitting = false);
    final booking = ref.read(bookingControllerProvider);
    if (booking.activeRequest != null && booking.errorMessage == null) {
      Navigator.of(context).pop(true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          booking.errorMessage ??
              'We could not create this booking. Try again.',
        ),
      ),
    );
  }

  Future<bool> _ensurePhoneVerified() async {
    try {
      final identity = await _pricingApi.loadCustomerIdentity();
      if (identity.phoneVerified) return true;
      if (!mounted) return false;
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => CustomerPhoneVerificationScreen(api: _pricingApi),
        ),
      );
      if (verified == true) return true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Verify your phone number to confirm this booking.')),
        );
      }
      return false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'We could not check phone verification. Please try again.')),
        );
      }
      return false;
    }
  }

  String get _scheduleSummary {
    if (_urgency == TaskUrgency.now) return 'As soon as possible';
    final selected = _scheduledAt;
    if (selected == null) return 'Time not selected';
    return DateFormat('EEE, d MMM · h:mm a').format(selected);
  }

  Future<void> _selectUrgency(TaskUrgency urgency) async {
    final now = DateTime.now();
    setState(() {
      _urgency = urgency;
      if (!BookingSchedulePolicy.isValid(
        urgency: urgency,
        scheduledAt: _scheduledAt,
        now: now,
      )) {
        _scheduledAt = null;
      }
    });
    if (urgency != TaskUrgency.now) await _pickSchedule();
  }

  Future<void> _pickSchedule() async {
    if (_urgency == TaskUrgency.today) {
      await _pickTodayTime();
    } else if (_urgency == TaskUrgency.scheduled) {
      await _pickLaterDateTime();
    }
  }

  Future<void> _pickTodayTime() async {
    final now = DateTime.now();
    final suggested = BookingSchedulePolicy.nextQuarterHour(now);
    if (suggested.day != now.day ||
        suggested.month != now.month ||
        suggested.year != now.year) {
      _showScheduleMessage(
        'There are no remaining booking times today. Choose Later instead.',
      );
      return;
    }
    final initial = _scheduledAt != null &&
            BookingSchedulePolicy.isValid(
              urgency: TaskUrgency.today,
              scheduledAt: _scheduledAt,
              now: now,
            )
        ? _scheduledAt!
        : suggested;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'SELECT A TIME FOR TODAY',
      confirmText: 'SET TIME',
    );
    if (picked == null || !mounted) return;
    final selected = DateTime(
      now.year,
      now.month,
      now.day,
      picked.hour,
      picked.minute,
    );
    if (!BookingSchedulePolicy.isValid(
      urgency: TaskUrgency.today,
      scheduledAt: selected,
      now: now,
    )) {
      _showScheduleMessage('Choose a time later than now and before midnight.');
      return;
    }
    setState(() => _scheduledAt = selected);
  }

  Future<void> _pickLaterDateTime() async {
    final now = DateTime.now();
    final firstDate = BookingSchedulePolicy.firstLaterDate(now);
    final lastDate = BookingSchedulePolicy.lastLaterDate(now);
    final current = _scheduledAt;
    final initialDate = current != null &&
            !current.isBefore(firstDate) &&
            !current.isAfter(lastDate.add(const Duration(days: 1)))
        ? current
        : firstDate;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'SELECT A DATE (NEXT 3 DAYS)',
      confirmText: 'NEXT',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: current != null
          ? TimeOfDay.fromDateTime(current)
          : const TimeOfDay(hour: 10, minute: 0),
      helpText: 'SELECT SERVICE TIME',
      confirmText: 'SET SCHEDULE',
    );
    if (time == null || !mounted) return;
    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!BookingSchedulePolicy.isValid(
      urgency: TaskUrgency.scheduled,
      scheduledAt: selected,
      now: now,
    )) {
      _showScheduleMessage('Choose a time within the next three days.');
      return;
    }
    setState(() => _scheduledAt = selected);
  }

  void _showScheduleMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  ServiceCategory _legacyCategory() {
    final preferredId = switch (widget.service.domainId) {
      'cleaning' => 'cleaner',
      'electrical' => 'electrician',
      'plumbing' => 'plumber',
      'carpentry' => 'carpenter',
      'painting' => 'painter',
      _ => 'labour',
    };
    return serviceCategories.firstWhere(
      (category) => category.id == preferredId,
      orElse: () => serviceCategories.last,
    );
  }
}

class _ServiceOptionPicker extends StatelessWidget {
  const _ServiceOptionPicker({
    required this.service,
    required this.city,
    required this.selectedId,
    required this.liveQuotes,
    required this.onChanged,
  });

  final ServiceDefinition service;
  final String city;
  final String? selectedId;

  /// Live quotes keyed by variant id. When an option has a live quote its
  /// price and duration come from there so the picker matches the estimate
  /// card; otherwise the bundled price book is used as an offline fallback.
  final Map<String, CustomerPricingQuote> liveQuotes;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final variants = WorkidaPricingCatalog.variantsForService(service.id);
    final selected = variants.firstWhere(
      (variant) => variant.id == selectedId,
      orElse: () => variants.first,
    );
    final details = _details(selected.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choose service option',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Color(0xFF183331),
          ),
        ),
        const SizedBox(height: 8),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const ValueKey('service-option-picker'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => _showOptions(context),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFB5DDD7)),
              ),
              child: Row(
                children: [
                  _OptionIcon(
                    icon: _serviceIcon,
                    imageAsset: service.imageAsset,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, .12),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Column(
                        key: ValueKey(selected.id),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selected.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF183331),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            details,
                            style: const TextStyle(
                              color: Color(0xFF526361),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE7F7F4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFF08786F),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _details(String variantId) {
    final live = liveQuotes[variantId];
    if (live != null) {
      return _formatDetails(
        live.estimate.estimatedTotal,
        live.config.estimatedDurationMinMinutes,
        live.config.estimatedDurationMaxMinutes,
      );
    }
    final config = WorkidaPricingCatalog.forService(
      service,
      variantId: variantId,
      city: city,
    );
    final estimate = PricingEngine.calculateEstimate(
      config: config,
      estimatedMinutes: config.estimatedDurationMinMinutes,
    );
    return _formatDetails(
      estimate.estimatedTotal,
      config.estimatedDurationMinMinutes,
      config.estimatedDurationMaxMinutes,
    );
  }

  String _formatDetails(Money total, int minMinutes, int maxMinutes) {
    final duration = minMinutes == maxMinutes
        ? durationLabel(minMinutes)
        : '${durationLabel(minMinutes)}–${durationLabel(maxMinutes)}';
    return '${total.formatted} · $duration';
  }

  Future<void> _showOptions(BuildContext context) async {
    final variants = WorkidaPricingCatalog.variantsForService(service.id);
    final result = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF8FBFA),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCAD5D3),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _OptionIcon(
                              icon: _serviceIcon,
                              imageAsset: service.imageAsset,
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Choose service option',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Select the scope that matches your home.',
                          style: TextStyle(color: Color(0xFF526361)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: variants.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final option = variants[index];
                  final isSelected = option.id == selectedId;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color:
                          isSelected ? const Color(0xFFE4F5F2) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: ValueKey('service-option-${option.id}'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.pop(context, option.id),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF08786F)
                                  : const Color(0xFFD7E2E0),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              _OptionIcon(
                                icon: isSelected
                                    ? Icons.check_rounded
                                    : _serviceIcon,
                                imageAsset:
                                    isSelected ? null : service.imageAsset,
                                selected: isSelected,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF183331),
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      _details(option.id),
                                      style: TextStyle(
                                        color: isSelected
                                            ? const Color(0xFF08786F)
                                            : const Color(0xFF526361),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF08786F)
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF08786F)
                                        : const Color(0xFF9BAEAB),
                                    width: 2,
                                  ),
                                ),
                                child: AnimatedScale(
                                  scale: isSelected ? 1 : 0,
                                  duration: const Duration(milliseconds: 180),
                                  child: const Icon(
                                    Icons.check_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null) onChanged(result);
  }

  IconData get _serviceIcon => switch (service.domainId) {
        'cleaning' => Icons.cleaning_services_outlined,
        'electrical' => Icons.electrical_services_outlined,
        'plumbing' => Icons.plumbing_outlined,
        'carpentry' => Icons.carpenter_outlined,
        'painting' => Icons.format_paint_outlined,
        _ => Icons.home_repair_service_outlined,
      };
}

class _OptionIcon extends StatelessWidget {
  const _OptionIcon({
    required this.icon,
    this.imageAsset,
    this.selected = false,
  });

  final IconData icon;
  final String? imageAsset;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF08786F) : const Color(0xFFE7F7F4),
          shape: BoxShape.circle,
        ),
        child: imageAsset == null
            ? Icon(
                icon,
                color: selected ? Colors.white : const Color(0xFF08786F),
                size: 21,
              )
            : ClipOval(
                child: Image.asset(
                  imageAsset!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    icon,
                    color: const Color(0xFF08786F),
                    size: 21,
                  ),
                ),
              ),
      );
}

class _ScheduleSelectionCard extends StatelessWidget {
  const _ScheduleSelectionCard({
    required this.urgency,
    required this.scheduledAt,
    required this.onTap,
  });

  final TaskUrgency urgency;
  final DateTime? scheduledAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = scheduledAt;
    final later = urgency == TaskUrgency.scheduled;
    final lastDate = BookingSchedulePolicy.lastLaterDate(DateTime.now());
    return Material(
      color:
          selected == null ? const Color(0xFFFFF8E7) : const Color(0xFFF1FAF8),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('booking-schedule-picker'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected == null
                  ? const Color(0xFFE5C66C)
                  : const Color(0xFFB5DDD7),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  later ? Icons.event_outlined : Icons.schedule_rounded,
                  color: const Color(0xFF08786F),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected == null
                          ? later
                              ? 'Select date and time'
                              : 'Select a time today'
                          : DateFormat('EEE, d MMM · h:mm a').format(selected),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF183331),
                      ),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: 4),
                      BookingCountdownLabel(scheduledAt: selected),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      later
                          ? 'Book through ${DateFormat('EEE, d MMM').format(lastDate)}'
                          : 'Available until midnight today',
                      style: const TextStyle(
                        color: Color(0xFF526361),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected == null ? Icons.chevron_right : Icons.edit_outlined,
                color: const Color(0xFF08786F),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationAndEstimateCard extends StatelessWidget {
  const _DurationAndEstimateCard({
    required this.config,
    required this.selectedMinutes,
    required this.estimate,
    required this.onChanged,
  });

  final ServicePricingConfig config;
  final int selectedMinutes;
  final PricingEstimate estimate;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final minimumMinutes = config.estimatedDurationMinMinutes;
    final maximumMinutes = config.estimatedDurationMaxMinutes;
    final selectionStep = math.max(config.billingIncrementMinutes, 15);
    final divisions =
        ((maximumMinutes - minimumMinutes) / selectionStep).floor();
    if (config.pricingModel != PricingModel.hourly) {
      return Container(
        key: const ValueKey('duration-and-estimate-card'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF3FAF8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFCBE6E1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              config.pricingModel == PricingModel.inspection ||
                      config.pricingModel == PricingModel.quote
                  ? 'Fixed-price assessment'
                  : 'Fixed price',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Estimated time: ${durationLabel(config.estimatedDurationMinMinutes)}'
              ' to ${durationLabel(config.estimatedDurationMaxMinutes)}',
            ),
            const SizedBox(height: 16),
            _PricingBreakdown(
              estimate: estimate,
              compact: true,
              config: config,
            ),
          ],
        ),
      );
    }
    return Container(
      key: const ValueKey('duration-and-estimate-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3FAF8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCBE6E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set the time you expect this service to take',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Choose your best estimate. Final labour uses verified working time.',
          ),
          const SizedBox(height: 18),
          Center(
            child: AnimatedContainer(
              key: const ValueKey('selected-duration'),
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFD9F4EF),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                '${durationLabel(selectedMinutes)} selected',
                style: const TextStyle(
                  color: Color(0xFF08786F),
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Estimated service hours',
            value: durationLabel(selectedMinutes),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF08786F),
                inactiveTrackColor: const Color(0xFFCAE2DE),
                thumbColor: const Color(0xFF08786F),
                overlayColor: const Color(0x2208786F),
                trackHeight: 6,
                showValueIndicator: ShowValueIndicator.onDrag,
              ),
              child: Slider(
                key: const ValueKey('estimated-hours-slider'),
                min: minimumMinutes.toDouble(),
                max: maximumMinutes.toDouble(),
                divisions: divisions > 0 ? divisions : null,
                value: selectedMinutes
                    .clamp(minimumMinutes, maximumMinutes)
                    .toDouble(),
                label: durationLabel(selectedMinutes),
                onChanged: divisions > 0
                    ? (minutes) {
                        final steps =
                            ((minutes - minimumMinutes) / selectionStep)
                                .round();
                        onChanged(
                          (minimumMinutes + steps * selectionStep)
                              .clamp(minimumMinutes, maximumMinutes),
                        );
                      }
                    : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(durationLabel(minimumMinutes)),
                Text(durationLabel(maximumMinutes)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _PricingBreakdown(
            estimate: estimate,
            compact: true,
            config: config,
          ),
        ],
      ),
    );
  }
}

class _PricingBreakdown extends StatelessWidget {
  const _PricingBreakdown({
    required this.estimate,
    required this.compact,
    required this.config,
  });

  final PricingEstimate estimate;
  final bool compact;
  final ServicePricingConfig config;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (estimate.visitFee.minorUnits > 0) ...[
            _PriceLine(
              label: config.pricingModel == PricingModel.inspection ||
                      config.pricingModel == PricingModel.quote
                  ? 'Fixed assessment price'
                  : 'Visit fee',
              value: estimate.visitFee.formatted,
            ),
            const SizedBox(height: 7),
          ],
          if (config.pricingModel == PricingModel.hourly &&
              config.customerBasePrice.minorUnits > 0) ...[
            _PriceLine(
              label:
                  'Base price · first ${durationLabel(config.includedDurationMinutes)}',
              value: config.customerBasePrice.formatted,
            ),
            if (estimate.labourAmount.minorUnits >
                config.customerBasePrice.minorUnits) ...[
              const SizedBox(height: 7),
              _PriceLine(
                label: 'Additional time · ${estimate.labourRate.formatted}/hr',
                value: Money.inrPaise(
                  estimate.labourAmount.minorUnits -
                      config.customerBasePrice.minorUnits,
                ).formatted,
              ),
            ],
          ] else if (estimate.labourAmount.minorUnits > 0)
            _PriceLine(
              label: 'Booked service labour',
              value: estimate.labourAmount.formatted,
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _PriceLine(
            label: config.pricingModel == PricingModel.inspection ||
                    config.pricingModel == PricingModel.quote
                ? 'Assessment total'
                : 'Estimated total',
            value: estimate.estimatedTotal.formatted,
            emphasized: true,
          ),
          SizedBox(height: compact ? 8 : 10),
          Text(
            config.pricingModel == PricingModel.hourly
                ? 'The base price includes the first ${durationLabel(config.includedDurationMinutes)}. Final labour uses verified working time, rounded to ${config.billingIncrementMinutes}-minute blocks. Additional time requires your approval.'
                : config.pricingModel == PricingModel.inspection ||
                        config.pricingModel == PricingModel.quote
                    ? 'This fixed price covers the assessment visit. Repair work and parts are quoted separately and require your approval.'
                    : 'This fixed price covers the selected scope and does not change with time. Any additional work requires your approval.',
            style: const TextStyle(
              color: Color(0xFF526361),
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      );
}

class _PriceLine extends StatelessWidget {
  const _PriceLine({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: emphasized ? FontWeight.w900 : FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            key: emphasized ? const ValueKey('estimated-total') : null,
            style: TextStyle(
              color: emphasized ? const Color(0xFF08786F) : null,
              fontSize: emphasized ? 20 : 14,
              fontWeight: emphasized ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
        ],
      );
}

class _BookingReviewHero extends StatelessWidget {
  const _BookingReviewHero(
      {required this.serviceName, required this.total, required this.duration});

  final String serviceName;
  final String total;
  final String duration;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF08786F),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
                color: Color(0x2608786F), blurRadius: 16, offset: Offset(0, 7))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('YOUR ESTIMATED TOTAL',
              style: TextStyle(
                  color: Color(0xFFC8F1EB),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1)),
          const SizedBox(height: 5),
          Text(total,
              key: const ValueKey('estimated-total'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 14),
          Container(height: 1, color: Colors.white24),
          const SizedBox(height: 13),
          Row(children: [
            const Icon(Icons.handyman_outlined,
                color: Color(0xFFC8F1EB), size: 19),
            const SizedBox(width: 8),
            Expanded(
                child: Text(serviceName,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800))),
            Text(duration,
                style: const TextStyle(
                    color: Color(0xFFC8F1EB), fontWeight: FontWeight.w700)),
          ]),
        ]),
      );
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard(
      {required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE0E9E7))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                    color: Color(0xFFE7F7F4), shape: BoxShape.circle),
                child: Icon(icon, size: 19, color: const Color(0xFF08786F))),
            const SizedBox(width: 10),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 16),
          child,
        ]),
      );
}

class _ReviewDetailRow extends StatelessWidget {
  const _ReviewDetailRow(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: const Color(0xFF08786F), size: 20),
        const SizedBox(width: 11),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF60706E),
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(value,
              style: const TextStyle(
                  color: Color(0xFF183331),
                  fontWeight: FontWeight.w700,
                  height: 1.3)),
        ])),
      ]);
}

class _InformationCard extends StatelessWidget {
  const _InformationCard({
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
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(message),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
