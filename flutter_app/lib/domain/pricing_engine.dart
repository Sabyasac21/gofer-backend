import 'dart:math' as math;

import '../data/workida_price_book.g.dart';
import 'service_catalog.dart';

enum PricingWorkerType { helper, professional }

enum PricingModel { fixed, hourly, inspection, quote, perUnit, tiered }

String _canonicalPricingModelName(String value) => switch (value) {
      'per_unit' => 'perUnit',
      'time_based' => 'hourly',
      _ => value,
    };

class Money {
  const Money._(this.minorUnits, this.currency);

  const Money.inrPaise(int paise) : this._(paise, 'INR');

  factory Money.inrRupees(int rupees) => Money.inrPaise(rupees * 100);

  final int minorUnits;
  final String currency;

  int get wholeRupees => minorUnits ~/ 100;

  String get formatted {
    final absolute = minorUnits.abs();
    final rupees = absolute ~/ 100;
    final paise = absolute % 100;
    final sign = minorUnits < 0 ? '-' : '';
    final whole = _withGrouping(rupees);
    return paise == 0
        ? '$sign₹$whole'
        : '$sign₹$whole.${paise.toString().padLeft(2, '0')}';
  }

  Map<String, Object> toJson() => {
        'minorUnits': minorUnits,
        'currency': currency,
      };

  static String _withGrouping(int value) {
    final digits = value.toString();
    if (digits.length <= 3) return digits;
    final tail = digits.substring(digits.length - 3);
    var head = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (head.length > 2) {
      groups.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) groups.insert(0, head);
    return '${groups.join(',')},$tail';
  }
}

class ServicePricingConfig {
  const ServicePricingConfig({
    required this.serviceId,
    required this.workerType,
    required this.profession,
    required this.skillLevel,
    required this.customerHourlyRate,
    required this.workerHourlyRate,
    required this.customerBasePrice,
    required this.workerBasePayout,
    required this.includedDurationMinutes,
    required this.billingIncrementMinutes,
    required this.customerVisitFee,
    required this.workerVisitPayout,
    required this.minimumCustomerLabour,
    required this.minimumWorkerLabour,
    required this.estimatedDurationMinMinutes,
    required this.estimatedDurationMaxMinutes,
    required this.overtimeEnabled,
    required this.overtimeCustomerRate,
    required this.overtimeWorkerRate,
    required this.pricingModel,
    required this.variantId,
    required this.unit,
    required this.quantity,
    required this.city,
    required this.inspectionFeeAbsorbed,
    required this.absorptionThreshold,
    this.includedScope = const [],
    this.exclusions = const [],
    this.active = true,
    this.disableVariants = false,
    this.version = WorkidaPriceBookData.version,
  })  : assert(estimatedDurationMinMinutes > 0),
        assert(estimatedDurationMaxMinutes >= estimatedDurationMinMinutes);

  final String serviceId;
  final PricingWorkerType workerType;
  final String profession;
  final String skillLevel;
  final Money customerHourlyRate;
  final Money workerHourlyRate;
  final Money customerBasePrice;
  final Money workerBasePayout;
  final int includedDurationMinutes;
  final int billingIncrementMinutes;
  final Money customerVisitFee;
  final Money workerVisitPayout;
  final Money minimumCustomerLabour;
  final Money minimumWorkerLabour;
  final int estimatedDurationMinMinutes;
  final int estimatedDurationMaxMinutes;
  final bool overtimeEnabled;
  final Money overtimeCustomerRate;
  final Money overtimeWorkerRate;
  final PricingModel pricingModel;
  final String variantId;
  final String unit;
  final int quantity;
  final String city;
  final bool inspectionFeeAbsorbed;
  final Money absorptionThreshold;
  final List<String> includedScope;
  final List<String> exclusions;
  final bool active;
  final bool disableVariants;
  final String version;

  Map<String, Object> toJson() => {
        'version': version,
        'serviceId': serviceId,
        'variantId': variantId,
        'pricingModel': pricingModel.name,
        'unit': unit,
        'quantity': quantity,
        'city': city,
        'workerType': workerType.name,
        'profession': profession,
        'skillLevel': skillLevel,
        'customerHourlyRateMinor': customerHourlyRate.minorUnits,
        'workerHourlyRateMinor': workerHourlyRate.minorUnits,
        'customerBasePriceMinor': customerBasePrice.minorUnits,
        'workerBasePayoutMinor': workerBasePayout.minorUnits,
        'includedDurationMinutes': includedDurationMinutes,
        'billingIncrementMinutes': billingIncrementMinutes,
        'customerVisitFeeMinor': customerVisitFee.minorUnits,
        'workerVisitPayoutMinor': workerVisitPayout.minorUnits,
        'minimumCustomerLabourMinor': minimumCustomerLabour.minorUnits,
        'minimumWorkerLabourMinor': minimumWorkerLabour.minorUnits,
        'estimatedDurationMinMinutes': estimatedDurationMinMinutes,
        'estimatedDurationMaxMinutes': estimatedDurationMaxMinutes,
        'overtimeEnabled': overtimeEnabled,
        'overtimeCustomerRateMinor': overtimeCustomerRate.minorUnits,
        'overtimeWorkerRateMinor': overtimeWorkerRate.minorUnits,
        'inspectionFeeAbsorbed': inspectionFeeAbsorbed,
        'absorptionThresholdMinor': absorptionThreshold.minorUnits,
        'currency': 'INR',
        'active': active,
        'disableVariants': disableVariants,
        'includedScope': includedScope,
        'exclusions': exclusions,
      };

  factory ServicePricingConfig.fromJson(Map<String, dynamic> json) {
    int minor(String key) => (json[key] as num?)?.toInt() ?? 0;
    final modelName = _canonicalPricingModelName(
      json['pricingModel'] as String? ?? 'hourly',
    );
    final workerTypeName = json['workerType'] as String? ?? 'professional';
    return ServicePricingConfig(
      serviceId: json['serviceId'] as String,
      workerType: PricingWorkerType.values.firstWhere(
        (value) => value.name == workerTypeName,
        orElse: () => PricingWorkerType.professional,
      ),
      profession: json['profession'] as String? ?? 'Professional',
      skillLevel: json['skillLevel'] as String? ?? 'standard',
      customerHourlyRate: Money.inrPaise(minor('customerHourlyRateMinor')),
      workerHourlyRate: Money.inrPaise(minor('workerHourlyRateMinor')),
      customerBasePrice: Money.inrPaise(
        minor('customerBasePriceMinor') == 0
            ? minor('minimumCustomerLabourMinor')
            : minor('customerBasePriceMinor'),
      ),
      workerBasePayout: Money.inrPaise(
        minor('workerBasePayoutMinor') == 0
            ? minor('minimumWorkerLabourMinor')
            : minor('workerBasePayoutMinor'),
      ),
      includedDurationMinutes:
          (json['includedDurationMinutes'] as num?)?.toInt() ?? 0,
      billingIncrementMinutes:
          (json['billingIncrementMinutes'] as num?)?.toInt() ?? 1,
      customerVisitFee: Money.inrPaise(minor('customerVisitFeeMinor')),
      workerVisitPayout: Money.inrPaise(minor('workerVisitPayoutMinor')),
      minimumCustomerLabour:
          Money.inrPaise(minor('minimumCustomerLabourMinor')),
      minimumWorkerLabour: Money.inrPaise(minor('minimumWorkerLabourMinor')),
      estimatedDurationMinMinutes:
          (json['estimatedDurationMinMinutes'] as num).toInt(),
      estimatedDurationMaxMinutes:
          (json['estimatedDurationMaxMinutes'] as num).toInt(),
      overtimeEnabled: json['overtimeEnabled'] as bool? ?? false,
      overtimeCustomerRate: Money.inrPaise(minor('overtimeCustomerRateMinor')),
      overtimeWorkerRate: Money.inrPaise(minor('overtimeWorkerRateMinor')),
      pricingModel: PricingModel.values.firstWhere(
        (value) => value.name == modelName,
        orElse: () => PricingModel.hourly,
      ),
      variantId: json['variantId'] as String? ?? json['serviceId'] as String,
      unit: json['unit'] as String? ?? 'service',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      city: json['city'] as String? ?? WorkidaPriceBookData.defaultCity,
      inspectionFeeAbsorbed: json['inspectionFeeAbsorbed'] as bool? ?? false,
      absorptionThreshold: Money.inrPaise(minor('absorptionThresholdMinor')),
      includedScope: _stringList(json['includedScope']),
      exclusions: _stringList(json['exclusions']),
      active: json['active'] as bool? ?? true,
      disableVariants: json['disableVariants'] as bool? ?? false,
      version: json['version'] as String? ?? WorkidaPriceBookData.version,
    );
  }
}

List<String> _stringList(Object? value) => value is List
    ? value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false)
    : const [];

class PricingEstimate {
  const PricingEstimate({
    required this.estimatedMinutes,
    required this.visitFee,
    required this.labourRate,
    required this.labourAmount,
    required this.estimatedTotal,
  });

  final int estimatedMinutes;
  final Money visitFee;
  final Money labourRate;
  final Money labourAmount;
  final Money estimatedTotal;

  factory PricingEstimate.fromJson(Map<String, dynamic> json) =>
      PricingEstimate(
        estimatedMinutes: (json['estimatedMinutes'] as num).toInt(),
        visitFee: Money.inrPaise(
          (json['visitFeeMinor'] as num?)?.toInt() ?? 0,
        ),
        labourRate: Money.inrPaise(
          (json['labourRateMinor'] as num?)?.toInt() ?? 0,
        ),
        labourAmount: Money.inrPaise(
          (json['labourAmountMinor'] as num?)?.toInt() ?? 0,
        ),
        estimatedTotal: Money.inrPaise(
          (json['estimatedTotalMinor'] as num?)?.toInt() ?? 0,
        ),
      );
}

class FinalPricingResult {
  const FinalPricingResult({
    required this.verifiedMinutes,
    required this.baseBillableMinutes,
    required this.approvedOvertimeMinutes,
    required this.visitFee,
    required this.customerLabour,
    required this.totalCustomerAmount,
    required this.customerAmountDue,
    required this.workerVisitPayout,
    required this.workerLabour,
    required this.workerPayout,
    required this.platformGrossMargin,
  });

  final int verifiedMinutes;
  final int baseBillableMinutes;
  final int approvedOvertimeMinutes;
  final Money visitFee;
  final Money customerLabour;
  final Money totalCustomerAmount;
  final Money customerAmountDue;
  final Money workerVisitPayout;
  final Money workerLabour;
  final Money workerPayout;
  final Money platformGrossMargin;
}

class CancellationPricingResult {
  const CancellationPricingResult({
    required this.customerCharge,
    required this.workerPayout,
  });

  final Money customerCharge;
  final Money workerPayout;
}

class PricingEngine {
  const PricingEngine._();

  static PricingEstimate calculateEstimate({
    required ServicePricingConfig config,
    required int estimatedMinutes,
  }) {
    _validateDuration(config, estimatedMinutes);
    final labour = config.pricingModel == PricingModel.hourly
        ? _hourlyAmount(config, estimatedMinutes, customer: true)
        : config.minimumCustomerLabour.minorUnits;
    return PricingEstimate(
      estimatedMinutes: estimatedMinutes,
      visitFee: config.customerVisitFee,
      labourRate: config.customerHourlyRate,
      labourAmount: Money.inrPaise(labour),
      estimatedTotal:
          Money.inrPaise(config.customerVisitFee.minorUnits + labour),
    );
  }

  static FinalPricingResult calculateFinal({
    required ServicePricingConfig config,
    required int estimatedMinutes,
    required int verifiedActualMinutes,
    required int approvedOvertimeMinutes,
    required bool visitFeePaid,
  }) {
    _validateDuration(config, estimatedMinutes);
    if (verifiedActualMinutes < 0 || approvedOvertimeMinutes < 0) {
      throw ArgumentError('Verified and overtime minutes cannot be negative.');
    }
    final hourly = config.pricingModel == PricingModel.hourly;
    final baseMinutes = hourly
        ? math.min(verifiedActualMinutes, estimatedMinutes)
        : estimatedMinutes;
    final actualExtra = math.max(verifiedActualMinutes - estimatedMinutes, 0);
    final overtimeMinutes = config.overtimeEnabled
        ? math.min(actualExtra, approvedOvertimeMinutes)
        : 0;
    final totalApprovedMinutes = baseMinutes + overtimeMinutes;
    final customerLabour = hourly
        ? _hourlyAmount(config, totalApprovedMinutes, customer: true)
        : config.minimumCustomerLabour.minorUnits;
    final workerLabour = hourly
        ? _hourlyAmount(config, totalApprovedMinutes, customer: false)
        : config.minimumWorkerLabour.minorUnits;
    final total = config.customerVisitFee.minorUnits + customerLabour;
    final payout = config.workerVisitPayout.minorUnits + workerLabour;
    return FinalPricingResult(
      verifiedMinutes: verifiedActualMinutes,
      baseBillableMinutes: baseMinutes,
      approvedOvertimeMinutes: overtimeMinutes,
      visitFee: config.customerVisitFee,
      customerLabour: Money.inrPaise(customerLabour),
      totalCustomerAmount: Money.inrPaise(total),
      customerAmountDue: Money.inrPaise(
        total - (visitFeePaid ? config.customerVisitFee.minorUnits : 0),
      ),
      workerVisitPayout: config.workerVisitPayout,
      workerLabour: Money.inrPaise(workerLabour),
      workerPayout: Money.inrPaise(payout),
      platformGrossMargin: Money.inrPaise(total - payout),
    );
  }

  static CancellationPricingResult calculateCancellation({
    required ServicePricingConfig config,
    required bool workerArrivalVerified,
    required bool cancelledByWorker,
  }) {
    if (cancelledByWorker || !workerArrivalVerified) {
      return const CancellationPricingResult(
        customerCharge: Money.inrPaise(0),
        workerPayout: Money.inrPaise(0),
      );
    }
    return CancellationPricingResult(
      customerCharge: config.customerVisitFee,
      workerPayout: config.workerVisitPayout,
    );
  }

  static int _prorated(int hourlyMinor, int minutes) =>
      ((hourlyMinor * minutes) + 30) ~/ 60;

  static int _hourlyAmount(
    ServicePricingConfig config,
    int minutes, {
    required bool customer,
  }) {
    if (minutes <= 0) return 0;
    final included = math.max(config.includedDurationMinutes, 0);
    final increment = math.max(config.billingIncrementMinutes, 1);
    final extraMinutes = math.max(minutes - included, 0);
    final roundedExtra =
        ((extraMinutes + increment - 1) ~/ increment) * increment;
    final base = customer
        ? config.customerBasePrice.minorUnits
        : config.workerBasePayout.minorUnits;
    final rate = customer
        ? config.customerHourlyRate.minorUnits
        : config.workerHourlyRate.minorUnits;
    final minimum = customer
        ? config.minimumCustomerLabour.minorUnits
        : config.minimumWorkerLabour.minorUnits;
    return math.max(base + _prorated(rate, roundedExtra), minimum);
  }

  static void _validateDuration(
    ServicePricingConfig config,
    int minutes,
  ) {
    if (minutes < config.estimatedDurationMinMinutes ||
        minutes > config.estimatedDurationMaxMinutes) {
      throw ArgumentError.value(minutes, 'estimatedMinutes');
    }
  }
}

class WorkidaPricingCatalog {
  const WorkidaPricingCatalog._();

  static final Map<String, ServicePricingConfig> _remoteOnlyEntries = {};
  static final Map<String, Map<String, dynamic>> _remoteEntries = {};
  static final Map<String, List<PriceBookVariant>> _remoteVariants = {};

  static void registerRemoteServices(List<Map<String, dynamic>> services) {
    for (final json in services) {
      final serviceId = json['serviceId'] as String?;
      if (serviceId == null) continue;
      _remoteEntries[serviceId] = Map<String, dynamic>.from(json);
      final variants = json['variants'];
      if (variants is List) {
        _remoteVariants[serviceId] = variants
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .map((item) => PriceBookVariant(
                  id: item['variantId'] as String? ?? item['id'] as String,
                  name: item['name'] as String? ?? 'Service option',
                  customerPriceMinor:
                      (item['customerPriceMinor'] as num?)?.toInt() ?? 0,
                  workerPayoutMinor:
                      (item['workerPayoutMinor'] as num?)?.toInt() ?? 0,
                  durationMinMinutes:
                      (item['durationMinMinutes'] as num?)?.toInt() ?? 10,
                  durationMaxMinutes:
                      (item['durationMaxMinutes'] as num?)?.toInt() ?? 10,
                ))
            .toList(growable: false);
      }
      if (WorkidaPriceBookData.entries.containsKey(serviceId)) continue;
      final modelName = _canonicalPricingModelName(
        json['pricingModel'] as String? ?? 'fixed',
      );
      final base = (json['basePriceMinor'] as num?)?.toInt() ?? 0;
      final visit = (json['visitFeeMinor'] as num?)?.toInt() ?? 0;
      final included = (json['includedDurationMinutes'] as num?)?.toInt() ?? 0;
      final hourlyRate = (json['hourlyRateMinor'] as num?)?.toInt() ?? 0;
      final catalog = json['catalog'];
      final template = catalog is Map ? catalog['template'] : null;
      final helper =
          template is Map && template['workforceCategory'] == 'helper';
      _remoteOnlyEntries[serviceId] = ServicePricingConfig.fromJson({
        'serviceId': serviceId,
        'workerType': helper ? 'helper' : 'professional',
        'profession': helper ? 'General Helper' : 'Professional',
        'customerBasePriceMinor': base,
        'workerBasePayoutMinor': 0,
        'customerHourlyRateMinor': hourlyRate,
        'workerHourlyRateMinor': 0,
        'includedDurationMinutes': included,
        'billingIncrementMinutes': json['billingIncrementMinutes'] ?? 15,
        'customerVisitFeeMinor': visit,
        'workerVisitPayoutMinor': 0,
        'minimumCustomerLabourMinor': base,
        'minimumWorkerLabourMinor': 0,
        'estimatedDurationMinMinutes': json['estimatedDurationMinMinutes'],
        'estimatedDurationMaxMinutes': json['estimatedDurationMaxMinutes'],
        'pricingModel': modelName,
        'variantId': serviceId,
        'unit': json['unit'] ?? 'service',
        'quantity': 1,
        'city': WorkidaPriceBookData.defaultCity,
        'includedScope': json['includedScope'] ?? const [],
        'exclusions': json['exclusions'] ?? const [],
        'active': json['active'] ?? false,
        'disableVariants': true,
      });
    }
  }

  static List<PriceBookVariant> variantsForService(String serviceId) =>
      _remoteVariants[serviceId] ??
      WorkidaPriceBookData.entries[serviceId]?.variants ??
      const [];

  static ServicePricingConfig forService(
    ServiceDefinition service, {
    String? variantId,
    String city = WorkidaPriceBookData.defaultCity,
    int quantity = 1,
  }) {
    final entry = WorkidaPriceBookData.entries[service.id];
    if (entry == null) {
      final remote = _remoteOnlyEntries[service.id];
      if (remote != null && remote.active) return remote;
      throw ArgumentError.value(
        service.id,
        'service',
        'No active price-book entry exists for this service.',
      );
    }
    if (quantity < 1 || quantity > 100) {
      throw ArgumentError.value(quantity, 'quantity');
    }
    final remote = _remoteEntries[service.id];
    if (remote?['active'] == false) {
      throw ArgumentError.value(
        service.id,
        'service',
        'Pricing is inactive for this service.',
      );
    }
    final adjustment = entry.cityAdjustments[city];
    if (adjustment == null) {
      throw ArgumentError.value(city, 'city', 'Unsupported pricing city.');
    }
    final variants = variantsForService(service.id);
    final variant = _variantFromList(variants, variantId);
    final remoteModelValue = remote?['pricingModel'] as String?;
    final remoteModel = remoteModelValue == null
        ? null
        : _canonicalPricingModelName(remoteModelValue);
    final model = remoteModel == null
        ? _model(entry.model)
        : PricingModel.values.firstWhere(
            (value) => value.name == remoteModel,
            orElse: () => _model(entry.model),
          );
    final inspection =
        model == PricingModel.inspection || model == PricingModel.quote;
    final hourly = model == PricingModel.hourly;
    final multiplierQuantity =
        hourly || inspection || model == PricingModel.tiered ? 1 : quantity;
    final remoteBase = (remote?['basePriceMinor'] as num?)?.toInt();
    final remoteWorkerBase =
        (remote?['workerBasePayoutMinor'] as num?)?.toInt();
    final customerBase =
        (variant?.customerPriceMinor ?? remoteBase ?? entry.basePriceMinor) *
            multiplierQuantity;
    final workerBase = (variant?.workerPayoutMinor ??
            remoteWorkerBase ??
            entry.workerBasePayoutMinor) *
        multiplierQuantity;
    final durationQuantity = model == PricingModel.perUnit ? quantity : 1;
    final durationMin = (variant?.durationMinMinutes ??
            (remote?['estimatedDurationMinMinutes'] as num?)?.toInt() ??
            entry.durationMinMinutes) *
        durationQuantity;
    final durationMax = (variant?.durationMaxMinutes ??
            (remote?['estimatedDurationMaxMinutes'] as num?)?.toInt() ??
            entry.durationMaxMinutes) *
        durationQuantity;
    final customerLabour = _adjust(
      customerBase,
      adjustment.customerMultiplier,
    );
    final workerLabour = _adjust(workerBase, adjustment.workerMultiplier);
    final minimumOrder = _adjust(
      entry.minimumOrderMinor,
      adjustment.customerMultiplier,
    );
    final overtimeCustomer = hourly
        ? _adjust(
            (remote?['hourlyRateMinor'] as num?)?.toInt() ??
                variant?.customerPriceMinor ??
                entry.hourlyRateMinor,
            adjustment.customerMultiplier,
          )
        : 0;
    final overtimeWorker = hourly
        ? _adjust(
            (remote?['workerHourlyRateMinor'] as num?)?.toInt() ??
                (entry.workerOvertimeRateMinor == 0
                    ? (variant?.workerPayoutMinor ??
                        entry.workerBasePayoutMinor)
                    : entry.workerOvertimeRateMinor),
            adjustment.workerMultiplier,
          )
        : 0;

    return ServicePricingConfig(
      serviceId: service.id,
      workerType: service.template.workforceCategory == WorkforceCategory.helper
          ? PricingWorkerType.helper
          : PricingWorkerType.professional,
      profession: _profession(service),
      skillLevel: 'standard',
      customerHourlyRate: Money.inrPaise(overtimeCustomer),
      workerHourlyRate: Money.inrPaise(overtimeWorker),
      customerBasePrice: Money.inrPaise(hourly ? customerLabour : 0),
      workerBasePayout: Money.inrPaise(hourly ? workerLabour : 0),
      includedDurationMinutes: hourly
          ? (remote?['includedDurationMinutes'] as num?)?.toInt() ??
              entry.includedDurationMinutes
          : 0,
      billingIncrementMinutes: hourly
          ? (remote?['billingIncrementMinutes'] as num?)?.toInt() ??
              entry.billingIncrementMinutes
          : 1,
      customerVisitFee: Money.inrPaise(
        _adjust(
          (remote?['visitFeeMinor'] as num?)?.toInt() ?? entry.visitFeeMinor,
          adjustment.customerMultiplier,
        ),
      ),
      workerVisitPayout: Money.inrPaise(
        _adjust(
          (remote?['workerVisitPayoutMinor'] as num?)?.toInt() ??
              entry.workerVisitPayoutMinor,
          adjustment.workerMultiplier,
        ),
      ),
      minimumCustomerLabour: Money.inrPaise(
        inspection ? 0 : math.max(customerLabour, minimumOrder),
      ),
      minimumWorkerLabour: Money.inrPaise(inspection ? 0 : workerLabour),
      estimatedDurationMinMinutes: durationMin,
      estimatedDurationMaxMinutes: durationMax,
      overtimeEnabled: hourly,
      overtimeCustomerRate: Money.inrPaise(overtimeCustomer),
      overtimeWorkerRate: Money.inrPaise(overtimeWorker),
      pricingModel: model,
      variantId: variant?.id ?? entry.serviceId,
      unit: entry.unit,
      quantity: quantity,
      city: city,
      inspectionFeeAbsorbed: entry.inspectionFeeAbsorbed,
      absorptionThreshold: Money.inrPaise(entry.absorptionThresholdMinor),
      includedScope: _stringList(remote?['includedScope']).isNotEmpty
          ? _stringList(remote?['includedScope'])
          : entry.includedScope,
      exclusions: _stringList(remote?['exclusions']).isNotEmpty
          ? _stringList(remote?['exclusions'])
          : entry.exclusions,
      active: remote?['active'] as bool? ?? true,
      disableVariants: variants.isEmpty,
      version:
          remote?['pricingVersion'] as String? ?? WorkidaPriceBookData.version,
    );
  }

  static String cityForAddress(String address) {
    final value = address.toLowerCase();
    if (value.contains('mumbai') || value.contains('navi mumbai')) {
      return 'mumbai';
    }
    if (value.contains('hyderabad')) return 'hyderabad';
    if (value.contains('pune')) return 'pune';
    if (value.contains('chennai')) return 'chennai';
    if (value.contains('kolkata')) return 'kolkata';
    if (value.contains('ahmedabad')) return 'ahmedabad';
    if (value.contains('delhi') ||
        value.contains('noida') ||
        value.contains('gurugram') ||
        value.contains('gurgaon') ||
        value.contains('faridabad') ||
        value.contains('ghaziabad')) {
      return 'delhi_ncr';
    }
    return 'bengaluru';
  }

  static PriceBookVariant? _variantFromList(
    List<PriceBookVariant> variants,
    String? variantId,
  ) {
    if (variants.isEmpty) return null;
    final selectedId = variantId ?? variants.first.id;
    for (final variant in variants) {
      if (variant.id == selectedId) return variant;
    }
    throw ArgumentError.value(variantId, 'variantId');
  }

  static PricingModel _model(PriceBookPricingModel model) => switch (model) {
        PriceBookPricingModel.fixed => PricingModel.fixed,
        PriceBookPricingModel.hourly => PricingModel.hourly,
        PriceBookPricingModel.inspection => PricingModel.inspection,
        PriceBookPricingModel.quote => PricingModel.quote,
        PriceBookPricingModel.perUnit => PricingModel.perUnit,
        PriceBookPricingModel.tiered => PricingModel.tiered,
      };

  static int _adjust(int amountMinor, double multiplier) =>
      ((amountMinor * multiplier) / 100).round() * 100;

  static String _profession(ServiceDefinition service) {
    final capability = service.capabilityKey?.toLowerCase() ?? '';
    if (service.domainId == 'plumbing') return 'Plumber';
    if (service.domainId == 'carpentry') return 'Carpenter';
    if (service.domainId == 'painting') return 'Painter';
    if (capability.contains('ac_') || capability.contains('cooler')) {
      return 'AC Technician';
    }
    const electricianIds = {
      'switch_socket_wiring_repair',
      'mcb_fuse_repair',
      'doorbell_repair',
      'voltage_power_issues',
      'fan_installation_repair',
      'lighting_installation',
      'decorative_light_installation',
      'fan_regulator_capacitor',
      'outdoor_sensor_light',
    };
    if (electricianIds.contains(service.id)) return 'Electrician';
    return service.template.workforceCategory == WorkforceCategory.helper
        ? 'General Helper'
        : 'Appliance Technician';
  }
}

String durationLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  if (hours == 0) return '$remaining ${remaining == 1 ? 'minute' : 'minutes'}';
  if (remaining == 0) return '$hours ${hours == 1 ? 'hour' : 'hours'}';
  return '$hours hr $remaining min';
}
