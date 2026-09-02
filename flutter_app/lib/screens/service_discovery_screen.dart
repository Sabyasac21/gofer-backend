import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workida_service_catalog.dart';
import '../domain/pricing_engine.dart';
import '../domain/service_catalog.dart';
import '../providers/service_catalog_provider.dart';
import '../services/rule_based_service_classifier.dart';
import '../services/customer_event_logger.dart';
import '../widgets/intelligent_service_input.dart';
import 'dynamic_job_booking_screen.dart';
import 'household_help_booking_screen.dart';

class ServiceDiscoveryScreen extends ConsumerStatefulWidget {
  const ServiceDiscoveryScreen({
    super.key,
    this.initialCategory,
    this.initialProblem,
    this.showBackButton = true,
    this.isActive = true,
    this.onBookingStarted,
  });

  final WorkforceCategory? initialCategory;
  final String? initialProblem;
  final bool showBackButton;
  final bool isActive;
  final VoidCallback? onBookingStarted;

  @override
  ConsumerState<ServiceDiscoveryScreen> createState() =>
      _ServiceDiscoveryScreenState();
}

class _ServiceDiscoveryScreenState extends ConsumerState<ServiceDiscoveryScreen>
    with WidgetsBindingObserver {
  static const _eventLogger = StructuredCustomerEventLogger();
  static const _promptExamples = [
    'Clean my whole 3 BHK flat',
    'My kitchen tap is leaking',
    'Need an electrician for my fan',
    'Help me move some furniture',
    'Need a helper for 4 hours',
    'Clean my bathroom and kitchen',
  ];
  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey _suggestionsKey = GlobalKey();
  late WorkforceCategory _category;
  Timer? _promptTimer;
  int _promptIndex = 0;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _listening = false;
  bool _showEmptyValidation = false;
  String? _domainId;
  String? _collectionId;
  List<ServiceClassification> _suggestions = const [];
  ServiceCatalog _catalog = workidaServiceCatalog;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(serviceCatalogProvider);
    });
    WidgetsBinding.instance.addObserver(this);
    _category = widget.initialCategory ?? WorkforceCategory.helper;
    _searchController = TextEditingController(text: widget.initialProblem);
    if (_searchController.text.trim().isNotEmpty) {
      _classify(_searchController.text);
    }
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _syncPromptTimer();
  }

  @override
  void didUpdateWidget(covariant ServiceDiscoveryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _syncPromptTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _lifecycleState == AppLifecycleState.resumed;
    _lifecycleState = state;
    _syncPromptTimer();
    if (state == AppLifecycleState.resumed && !wasResumed && mounted) {
      // Pick up catalogue and pricing changes an admin published while the app
      // was in the background, without needing a full restart.
      ref.invalidate(serviceCatalogProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptTimer?.cancel();
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _scrollController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _catalog = ref.watch(serviceCatalogProvider).asData?.value ??
        workidaServiceCatalog;
    final domains = _catalog.domainsFor(_category);
    final visibleServices = _collectionId != null
        ? _catalog.servicesForCollection(_collectionId!)
        : _domainId == null
            ? _catalog.services
                .where(
                  (service) =>
                      service.active &&
                      service.template.workforceCategory == _category,
                )
                .take(6)
                .toList(growable: false)
            : _catalog.servicesForDomain(_domainId!);

    return PopScope(
      canPop: _domainId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _domainId == null) return;
        _clearDomain();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7FAF9),
        body: SafeArea(
          bottom: false,
          child: ColoredBox(
            color: const Color(0xFFF7FAF9),
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(serviceCatalogProvider);
                try {
                  await ref.read(serviceCatalogProvider.future);
                } catch (_) {
                  // Keep the last catalogue visible if the refresh fails.
                }
              },
              child: ListView(
                controller: _scrollController,
                padding: EdgeInsets.zero,
                children: [
                  if (_domainId == null)
                    _CompactDiscoveryHeader(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      suggestion: _promptExamples[_promptIndex],
                      active: widget.isActive,
                      showEmptyValidation: _showEmptyValidation,
                      onBack: widget.showBackButton
                          ? () => Navigator.of(context).maybePop()
                          : null,
                      onChanged: _handleProblemChanged,
                      onSubmit: _submitProblem,
                      onListeningChanged: _handleListeningChanged,
                    )
                  else
                    _CategoryNavigationHeader(
                      domain: domains
                          .firstWhere((domain) => domain.id == _domainId),
                      onBack: _clearDomain,
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        20, _domainId == null ? 20 : 16, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_searchController.text.trim().isNotEmpty) ...[
                          SizedBox(key: _suggestionsKey),
                          Text('Suggested services',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 10),
                          if (_suggestions.isEmpty)
                            const _NoSuggestionCard()
                          else
                            ..._suggestions.map(
                              (result) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _ServiceTile(
                                  service: result.service,
                                  caption:
                                      '${(result.confidence * 100).round()}% match · ${result.service.shortDescription}',
                                  onTap: () => _openService(
                                    result.service,
                                    initialAnswers: result.extractedAnswers,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],
                        if (_domainId == null) ...[
                          Text(
                            'Popular services',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -.5,
                                ),
                          ),
                          const SizedBox(height: 14),
                          _WorkforceCategorySwitcher(
                            value: _category,
                            hintEnabled: widget.isActive,
                            onChanged: (value) => setState(() {
                              _category = value;
                              _domainId = null;
                              _collectionId = null;
                            }),
                          ),
                          const SizedBox(height: 18),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: .86,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: domains.length,
                            itemBuilder: (context, index) {
                              final domain = domains[index];
                              return _DomainCard(
                                domain: domain,
                                selected: false,
                                onTap: () => _selectDomain(domain.id),
                              );
                            },
                          ),
                          const SizedBox(height: 24),
                        ],
                        if (_domainId == 'cleaning')
                          _CleaningCatalog(
                            services: visibleServices,
                            collections:
                                _catalog.collectionsForDomain('cleaning'),
                            selectedCollectionId: _collectionId,
                            onCollectionSelected: (id) =>
                                setState(() => _collectionId = id),
                            onServiceSelected: _openService,
                          )
                        else if (_domainId == 'household')
                          if (_catalog
                                  .serviceById('household_help_session')
                                  ?.active ==
                              true)
                            _HouseholdHelpOverview(onStart: _openHouseholdHelp)
                          else
                            const _NoSuggestionCard()
                        else if (_domainId != null &&
                            const {
                              'electrical',
                              'painting',
                              'plumbing',
                              'carpentry',
                            }.contains(_domainId))
                          _ProfessionalCatalog(
                            domain: domains.firstWhere(
                              (domain) => domain.id == _domainId,
                            ),
                            services: visibleServices,
                            collections:
                                _catalog.collectionsForDomain(_domainId!),
                            onServiceSelected: _openService,
                            onDescribeProblem: _domainId == 'electrical'
                                ? _describeElectricalProblem
                                : null,
                          )
                        else ...[
                          Text(
                            _domainId == null
                                ? 'Common ${_category == WorkforceCategory.helper ? 'helper' : 'professional'} services'
                                : domains
                                    .firstWhere(
                                        (domain) => domain.id == _domainId)
                                    .name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          ...visibleServices.map(
                            (service) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _ServiceTile(
                                service: service,
                                caption: service.shortDescription,
                                onTap: () => _openService(service),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _shouldRotatePrompts =>
      widget.isActive &&
      _lifecycleState == AppLifecycleState.resumed &&
      !_searchFocusNode.hasFocus &&
      !_listening &&
      _searchController.text.trim().isEmpty;

  void _syncPromptTimer() {
    _promptTimer?.cancel();
    _promptTimer = null;
    if (!_shouldRotatePrompts) return;
    _promptTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_shouldRotatePrompts) return;
      setState(
        () => _promptIndex = (_promptIndex + 1) % _promptExamples.length,
      );
    });
  }

  void _handleSearchFocusChanged() {
    if (mounted) setState(() {});
    _syncPromptTimer();
  }

  void _handleListeningChanged(bool listening) {
    if (!mounted) return;
    setState(() => _listening = listening);
    _syncPromptTimer();
  }

  void _handleProblemChanged(String problem) {
    if (_showEmptyValidation && problem.trim().isNotEmpty) {
      setState(() => _showEmptyValidation = false);
    }
    _classify(problem);
    _syncPromptTimer();
  }

  void _submitProblem() {
    final problem = _searchController.text.trim();
    if (problem.isEmpty) {
      setState(() => _showEmptyValidation = true);
      _searchFocusNode.requestFocus();
      return;
    }
    if (_showEmptyValidation) {
      setState(() => _showEmptyValidation = false);
    }
    _classify(problem);
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _suggestionsKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: .08,
      );
    });
  }

  void _classify(String problem) {
    final classifier = RuleBasedServiceClassifier(_catalog);
    setState(() => _suggestions = classifier.classify(problem));
  }

  void _selectDomain(String domainId) {
    setState(() {
      _domainId = domainId;
      _collectionId = null;
    });
    _resetScrollPosition();
  }

  void _clearDomain() {
    setState(() {
      _domainId = null;
      _collectionId = null;
    });
    _resetScrollPosition();
  }

  void _describeElectricalProblem() {
    setState(() {
      _category = WorkforceCategory.professional;
      _domainId = null;
      _collectionId = null;
      _searchController.clear();
      _suggestions = const [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      _searchFocusNode.requestFocus();
    });
  }

  void _resetScrollPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  Future<void> _openService(
    ServiceDefinition service, {
    Map<String, Object> initialAnswers = const {},
  }) async {
    if (service.id == 'household_help_session' ||
        service.id == 'packing_help') {
      await _openHouseholdHelp(
        initialChoreId: service.id == 'packing_help' ? 'packing' : null,
      );
      return;
    }
    _eventLogger.log(
      CustomerOperationEvent.serviceSelected,
      attributes: {
        'serviceId': service.id,
        'workforceCategory': service.template.workforceCategory.name,
        'source': _searchController.text.trim().isEmpty ? 'browse' : 'search',
      },
    );
    final booked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DynamicJobBookingScreen(
          service: service,
          initialAnswers: initialAnswers,
        ),
      ),
    );
    if (booked != true || !mounted) return;
    final onBookingStarted = widget.onBookingStarted;
    if (onBookingStarted != null) {
      onBookingStarted();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openHouseholdHelp({String? initialChoreId}) async {
    final booked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => HouseholdHelpBookingScreen(
          initialChoreId: initialChoreId,
        ),
      ),
    );
    if (booked != true || !mounted) return;
    final onBookingStarted = widget.onBookingStarted;
    if (onBookingStarted != null) {
      onBookingStarted();
    } else {
      Navigator.of(context).pop(true);
    }
  }
}

class _WorkforceCategorySwitcher extends StatefulWidget {
  const _WorkforceCategorySwitcher({
    required this.value,
    required this.hintEnabled,
    required this.onChanged,
  });

  final WorkforceCategory value;
  final bool hintEnabled;
  final ValueChanged<WorkforceCategory> onChanged;

  @override
  State<_WorkforceCategorySwitcher> createState() =>
      _WorkforceCategorySwitcherState();
}

class _WorkforceCategorySwitcherState extends State<_WorkforceCategorySwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hintController;
  late final Animation<double> _professionalPulse;
  Timer? _hintTimer;
  bool _hintPlayed = false;

  @override
  void initState() {
    super.initState();
    _hintController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _professionalPulse = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 10),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: 1).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: 0).chain(
          CurveTween(curve: Curves.easeInCubic),
        ),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 10),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: 1).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: 0).chain(
          CurveTween(curve: Curves.easeInCubic),
        ),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 10),
    ]).animate(_hintController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleHint());
  }

  @override
  void didUpdateWidget(covariant _WorkforceCategorySwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hintEnabled || widget.value == WorkforceCategory.professional) {
      _stopHint();
    } else if (!oldWidget.hintEnabled || oldWidget.value != widget.value) {
      _scheduleHint();
    }
  }

  void _scheduleHint() {
    if (!mounted ||
        _hintPlayed ||
        !widget.hintEnabled ||
        widget.value != WorkforceCategory.helper) {
      return;
    }
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      final reduceMotion =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      _hintPlayed = true;
      if (!reduceMotion) _hintController.forward(from: 0);
    });
  }

  void _stopHint() {
    _hintPlayed = true;
    _hintTimer?.cancel();
    _hintController.stop();
    _hintController.value = 0;
  }

  void _select(WorkforceCategory value) {
    _stopHint();
    if (value != widget.value) widget.onChanged(value);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hintController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const borderColor = Color(0xFF8BA19E);
    const selectedColor = Color(0xFFD8F1EE);
    const accentColor = Color(0xFF087F75);

    return Semantics(
      container: true,
      label: 'Worker category',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            key: const ValueKey('workforce-category-switcher'),
            height: 44,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0A112D29),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(2),
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      alignment: widget.value == WorkforceCategory.helper
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: FractionallySizedBox(
                        widthFactor: .5,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: selectedColor,
                            borderRadius: BorderRadius.circular(21),
                          ),
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _professionalPulse,
                    builder: (context, child) {
                      final pulse = _professionalPulse.value;
                      return Positioned(
                        key: const ValueKey('professional-category-hint'),
                        top: 2,
                        right: 2,
                        bottom: 2,
                        width: (constraints.maxWidth - 4) / 2,
                        child: IgnorePointer(
                          child: Transform.scale(
                            scale: 1 + (.025 * pulse),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(21),
                                border: Border.all(
                                  color: accentColor.withValues(
                                    alpha: .85 * pulse,
                                  ),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: accentColor.withValues(
                                      alpha: .24 * pulse,
                                    ),
                                    blurRadius: 16 * pulse,
                                    spreadRadius: 1.5 * pulse,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _WorkforceCategorySegment(
                            label: 'Helper',
                            icon: Icons.cleaning_services_outlined,
                            selected: widget.value == WorkforceCategory.helper,
                            onTap: () => _select(WorkforceCategory.helper),
                          ),
                        ),
                        Expanded(
                          child: _WorkforceCategorySegment(
                            label: 'Professional',
                            icon: Icons.handyman_outlined,
                            selected:
                                widget.value == WorkforceCategory.professional,
                            onTap: () =>
                                _select(WorkforceCategory.professional),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkforceCategorySegment extends StatelessWidget {
  const _WorkforceCategorySegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected
                      ? const Color(0xFF087F75)
                      : const Color(0xFF3B4B49),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xFF263734),
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _CompactDiscoveryHeader extends StatelessWidget {
  const _CompactDiscoveryHeader({
    required this.controller,
    required this.focusNode,
    required this.suggestion,
    required this.active,
    required this.showEmptyValidation,
    this.onBack,
    required this.onChanged,
    required this.onSubmit,
    required this.onListeningChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String suggestion;
  final bool active;
  final bool showEmptyValidation;
  final VoidCallback? onBack;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final ValueChanged<bool> onListeningChanged;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: const Color(0xFF17212B),
          fontWeight: FontWeight.w900,
          letterSpacing: -.6,
        );
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFEAF7F5),
        border: Border(
          bottom: BorderSide(color: Color(0xFFD4E9E6)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onBack != null) ...[
              IconButton(
                tooltip: 'Back',
                onPressed: onBack,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(height: 4),
            ],
            Text('What do you need help with?', style: titleStyle),
            const SizedBox(height: 12),
            IntelligentServiceInput(
              controller: controller,
              focusNode: focusNode,
              suggestion: suggestion,
              active: active,
              showEmptyValidation: showEmptyValidation,
              onChanged: onChanged,
              onSubmit: onSubmit,
              onListeningChanged: onListeningChanged,
            ),
            const SizedBox(height: 12),
            const Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _CompactTrustItem(
                  icon: Icons.verified_user_outlined,
                  label: 'Verified workers',
                ),
                _CompactTrustItem(
                  icon: Icons.receipt_long_outlined,
                  label: 'Transparent labour',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactTrustItem extends StatelessWidget {
  const _CompactTrustItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFF08786F), size: 17),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF334542),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
}

class LegacyDiscoveryHero extends StatelessWidget {
  const LegacyDiscoveryHero({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.prompt,
    this.onBack,
    required this.onChanged,
    required this.onPromptTap,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String prompt;
  final VoidCallback? onBack;
  final ValueChanged<String> onChanged;
  final VoidCallback onPromptTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF073B3A), Color(0xFF08786F), Color(0xFF16A89C)],
          stops: [0, .58, 1],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Stack(
        children: [
          const Positioned(
            right: -38,
            top: -34,
            child: _GlowOrb(size: 170, color: Color(0x335AF0D9)),
          ),
          const Positioned(
            left: -55,
            bottom: -80,
            child: _GlowOrb(size: 190, color: Color(0x22FFFFFF)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (onBack != null) ...[
                  IconButton.filledTonal(
                    tooltip: 'Back',
                    onPressed: onBack,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: .15),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(height: 12),
                ],
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'What would make\ntoday easier?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      height: 1.05,
                      letterSpacing: -1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Tell us naturally. We’ll find the right skilled person.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .82),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textInputAction: TextInputAction.search,
                  onChanged: onChanged,
                  onSubmitted: onChanged,
                  style: const TextStyle(
                    color: Color(0xFF102624),
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    hintText: 'Describe the work you need',
                    hintStyle: const TextStyle(color: Color(0xFF71817F)),
                    prefixIcon: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Color(0xFF08786F),
                    ),
                    suffixIcon: controller.text.isEmpty
                        ? const Icon(
                            Icons.arrow_forward_rounded,
                            color: Color(0xFF08786F),
                          )
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: onClear,
                            icon: const Icon(Icons.close_rounded),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: const BorderSide(
                        color: Color(0xFFB9FFF4),
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
                const SizedBox(height: 11),
                Semantics(
                  button: true,
                  label: 'Use example: $prompt',
                  child: InkWell(
                    onTap: onPromptTap,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline_rounded,
                            size: 17,
                            color: Colors.white.withValues(alpha: .78),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            'Try',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .68),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 450),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, .35),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                              child: Text(
                                '“$prompt”',
                                key: ValueKey(prompt),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Row(
                  children: [
                    Expanded(
                      child: _TrustItem(
                        icon: Icons.verified_user_outlined,
                        label: 'Verified workers',
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: _TrustItem(
                        icon: Icons.receipt_long_outlined,
                        label: 'Clear pricing',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class _TrustItem extends StatelessWidget {
  const _TrustItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: const Color(0xFFC8FFF5), size: 17),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
}

class _DomainCard extends StatelessWidget {
  const _DomainCard({
    required this.domain,
    required this.selected,
    required this.onTap,
  });

  final ServiceDomainDefinition domain;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${domain.name}. ${domain.description}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (domain.imageAsset != null)
                Image.asset(
                  domain.imageAsset!,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Color(0xFFD9F5F0),
                  ),
                )
              else
                const ColoredBox(color: Color(0xFFD9F5F0)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x08000000), Color(0xE6001917)],
                    stops: [.3, 1],
                  ),
                ),
              ),
              Positioned(
                top: 11,
                left: 11,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _domainIcon(domain.id),
                    size: 20,
                    color: const Color(0xFF08786F),
                  ),
                ),
              ),
              Positioned(
                left: 13,
                right: 13,
                bottom: 13,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      domain.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      domain.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .82),
                        fontSize: 11,
                        height: 1.2,
                      ),
                    ),
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

class _CategoryNavigationHeader extends StatelessWidget {
  const _CategoryNavigationHeader({required this.domain, required this.onBack});

  final ServiceDomainDefinition domain;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF7FAF9),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 20, 12),
        child: Row(children: [
          IconButton(
            onPressed: onBack,
            tooltip: 'Back to categories',
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(domain.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(domain.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: const Color(0xFF60706E))),
              ])),
        ]),
      ),
    );
  }
}

class _ProfessionalCatalog extends StatelessWidget {
  const _ProfessionalCatalog({
    required this.domain,
    required this.services,
    required this.collections,
    required this.onServiceSelected,
    this.onDescribeProblem,
  });

  final ServiceDomainDefinition domain;
  final List<ServiceDefinition> services;
  final List<ServiceCollectionDefinition> collections;
  final ValueChanged<ServiceDefinition> onServiceSelected;
  final VoidCallback? onDescribeProblem;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${domain.name} services',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 5),
        Text(
          'Choose the exact service so we can ask the right questions and match the right verified professional.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF526361),
              ),
        ),
        const SizedBox(height: 18),
        ...collections.map((collection) {
          final collectionServices = services
              .where((service) => service.collectionId == collection.id)
              .toList(growable: false);
          if (collectionServices.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  collection.name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 3),
                Text(
                  collection.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF60706E),
                      ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 352,
                  child: ListView.separated(
                    key: ValueKey('professional-section-${collection.id}'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 8),
                    itemCount: collectionServices.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final service = collectionServices[index];
                      return SizedBox(
                        width: (MediaQuery.sizeOf(context).width * .67)
                            .clamp(224.0, 270.0),
                        child: _ProfessionalServiceCard(
                          service: service,
                          onTap: () => onServiceSelected(service),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        }),
        if (onDescribeProblem != null)
          Card(
            margin: EdgeInsets.zero,
            color: const Color(0xFFE2F7F3),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Couldn’t find your issue?',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Describe the electrical problem in your own words and we’ll guide you to the closest service.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: onDescribeProblem,
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('Describe your electrical problem'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ProfessionalServiceCard extends StatelessWidget {
  const _ProfessionalServiceCard({required this.service, required this.onTap});

  final ServiceDefinition service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final priceLabel = _servicePriceLabel(service);
    return Semantics(
      button: true,
      label: '${service.name}. ${service.shortDescription}. $priceLabel',
      child: Card(
        key: ValueKey('service-card-${service.id}'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1.16,
                child: service.imageAsset == null
                    ? ColoredBox(
                        color: const Color(0xFFD8F4F0),
                        child: Icon(
                          _domainIcon(service.domainId),
                          color: const Color(0xFF08786F),
                          size: 42,
                        ),
                      )
                    : Image.asset(
                        service.imageAsset!,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        errorBuilder: (_, __, ___) => const ColoredBox(
                          color: Color(0xFFD8F4F0),
                          child: Icon(Icons.home_repair_service_outlined),
                        ),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        service.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Expanded(
                        child: Text(
                          service.shortDescription,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF586764),
                                    height: 1.25,
                                  ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              priceLabel,
                              key: ValueKey('service-price-${service.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF08786F),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: Color(0xFF08786F),
                          ),
                        ],
                      ),
                    ],
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

class _HouseholdHelpOverview extends StatelessWidget {
  const _HouseholdHelpOverview({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    const chores = [
      (Icons.soup_kitchen_outlined, 'Dishes'),
      (Icons.cleaning_services_outlined, 'Sweep & mop'),
      (Icons.local_laundry_service_outlined, 'Laundry'),
      (Icons.bed_outlined, 'Room reset'),
      (Icons.inventory_2_outlined, 'Organising'),
      (Icons.card_giftcard_outlined, 'Packing'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          child: SizedBox(
            height: 250,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/images/categories/household.jpg',
                  fit: BoxFit.cover,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x10000000), Color(0xE600201D)],
                      stops: [.2, 1],
                    ),
                  ),
                ),
                const Positioned(
                  left: 18,
                  right: 18,
                  bottom: 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'One helper. Several chores.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Build a fair, time-boxed session around your routine household needs.',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'What can a helper assist with?',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Select multiple chores, describe the workload and get a realistic duration recommendation.',
        ),
        const SizedBox(height: 14),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 2.4,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: chores.length,
          itemBuilder: (context, index) => DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFE8F8F5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(chores[index].$1, color: const Color(0xFF08786F)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chores[index].$2,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF5E5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFF9A5A00)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'For deep cleaning, specialist equipment, repairs or heavy lifting, choose the dedicated Workida category instead.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Build my help session'),
          ),
        ),
      ],
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.caption,
    required this.onTap,
  });

  final ServiceDefinition service;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        minVerticalPadding: 14,
        leading: service.imageAsset == null
            ? CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  _domainIcon(service.domainId),
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  service.imageAsset!,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
              ),
        title: Text(
          service.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(caption),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _CleaningCatalog extends StatelessWidget {
  const _CleaningCatalog({
    required this.services,
    required this.collections,
    required this.selectedCollectionId,
    required this.onCollectionSelected,
    required this.onServiceSelected,
  });

  final List<ServiceDefinition> services;
  final List<ServiceCollectionDefinition> collections;
  final String? selectedCollectionId;
  final ValueChanged<String?> onCollectionSelected;
  final ValueChanged<ServiceDefinition> onServiceSelected;

  @override
  Widget build(BuildContext context) {
    final featured =
        services.where((service) => service.isFeatured).firstOrNull;
    final gridServices = selectedCollectionId == null && featured != null
        ? services.where((service) => service.id != featured.id).toList()
        : services;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Cleaning services',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 5),
        Text(
          'Choose a complete package or focus on one room, surface or item.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: selectedCollectionId == null,
                  onSelected: (_) => onCollectionSelected(null),
                ),
              ),
              ...collections.map(
                (collection) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(collection.name),
                    selected: selectedCollectionId == collection.id,
                    onSelected: (_) => onCollectionSelected(collection.id),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (featured != null) ...[
          const SizedBox(height: 16),
          _CleaningHeroCard(
            service: featured,
            onTap: () => onServiceSelected(featured),
          ),
        ],
        const SizedBox(height: 18),
        if (selectedCollectionId != null) ...[
          Text(
            collections
                .firstWhere((item) => item.id == selectedCollectionId)
                .description,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
        ],
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: .68,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: gridServices.length,
          itemBuilder: (context, index) {
            final service = gridServices[index];
            return _CleaningServiceCard(
              service: service,
              onTap: () => onServiceSelected(service),
            );
          },
        ),
      ],
    );
  }
}

class _CleaningHeroCard extends StatelessWidget {
  const _CleaningHeroCard({required this.service, required this.onTap});

  final ServiceDefinition service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${service.name}. ${service.shortDescription}. '
          '${_servicePriceLabel(service)}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 220,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ServiceAssetImage(service: service),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xE6000000)],
                      stops: [.28, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (service.badge != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            service.badge!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      Text(
                        service.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${service.shortDescription}\n${_servicePriceLabel(service)}',
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CleaningServiceCard extends StatelessWidget {
  const _CleaningServiceCard({required this.service, required this.onTap});

  final ServiceDefinition service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${service.name}. ${service.shortDescription}. '
          '${_servicePriceLabel(service)}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ServiceAssetImage(service: service),
                    if (service.badge != null)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            service.badge!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      service.shortDescription,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _servicePriceLabel(service),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
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

class _ServiceAssetImage extends StatelessWidget {
  const _ServiceAssetImage({required this.service});

  final ServiceDefinition service;

  @override
  Widget build(BuildContext context) {
    final asset = service.imageAsset;
    if (asset == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          _domainIcon(service.domainId),
          color: Theme.of(context).colorScheme.primary,
          size: 42,
        ),
      );
    }
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, _, __) => ColoredBox(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          _domainIcon(service.domainId),
          color: Theme.of(context).colorScheme.primary,
          size: 42,
        ),
      ),
    );
  }
}

class _NoSuggestionCard extends StatelessWidget {
  const _NoSuggestionCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.search_off,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'No clear match yet. Try a simpler description or browse the categories below.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _domainIcon(String id) => switch (id) {
      'cleaning' => Icons.cleaning_services_outlined,
      'household' => Icons.home_outlined,
      'moving' => Icons.local_shipping_outlined,
      'outdoor' => Icons.yard_outlined,
      'electrical' => Icons.electrical_services_outlined,
      'plumbing' => Icons.plumbing_outlined,
      'carpentry' => Icons.carpenter_outlined,
      'painting' => Icons.format_paint_outlined,
      'cooling' => Icons.ac_unit_outlined,
      'appliances' => Icons.home_repair_service_outlined,
      _ => Icons.handyman_outlined,
    };

String _servicePriceLabel(ServiceDefinition service) {
  final config = WorkidaPricingCatalog.forService(service);
  final estimate = PricingEngine.calculateEstimate(
    config: config,
    estimatedMinutes: config.estimatedDurationMinMinutes,
  );
  return 'From ${estimate.estimatedTotal.formatted} · visit included';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
