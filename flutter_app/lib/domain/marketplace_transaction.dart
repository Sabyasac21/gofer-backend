enum RequirementKind { material, specialTool }

enum RequirementStatus {
  requested,
  acknowledged,
  arranged,
  confirmed,
  cancelled,
  rejected,
}

enum TimeSegmentType {
  working,
  customerWaiting,
  workerBreak,
  workerDelay,
  systemPause,
  materialWait,
  specialToolWait,
}

enum AdditionalWorkStatus { pending, approved, declined, expired, cancelled }

enum MarketplacePaymentStatus {
  notRequired,
  pending,
  processing,
  success,
  failed,
  cancelled,
  refundPending,
  refunded,
  partiallyRefunded,
}

DateTime? _dateTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? _string(Object? value) => value?.toString();

int _integer(Object? value) => switch (value) {
      int number => number,
      num number => number.toInt(),
      String text => int.tryParse(text) ?? 0,
      _ => 0,
    };

int? _nullableInteger(Object? value) => value == null ? null : _integer(value);

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : const [];

class JobRequirement {
  const JobRequirement({
    required this.id,
    required this.kind,
    required this.description,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.quantity,
    this.imageUri,
    this.standardTool = false,
  });

  factory JobRequirement.fromJson(Map<String, dynamic> json) => JobRequirement(
        id: _string(json['id']) ?? '',
        kind: json['kind'] == 'special_tool'
            ? RequirementKind.specialTool
            : RequirementKind.material,
        description: _string(json['description']) ?? '',
        quantity: _string(json['quantity']),
        reason: _string(json['reason']) ?? '',
        imageUri: _string(json['image_uri']),
        standardTool: json['standard_tool'] == true,
        status: RequirementStatus.values.firstWhere(
          (status) => status.name == json['status'],
          orElse: () => RequirementStatus.requested,
        ),
        createdAt: _dateTime(json['created_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  final RequirementKind kind;
  final String description;
  final String? quantity;
  final String reason;
  final String? imageUri;
  final bool standardTool;
  final RequirementStatus status;
  final DateTime createdAt;

  bool get customerActionRequired =>
      status == RequirementStatus.requested ||
      status == RequirementStatus.acknowledged;
}

class JobTimeSegment {
  const JobTimeSegment({
    required this.id,
    required this.type,
    required this.startedAt,
    required this.waitingCompensation,
    this.endedAt,
    this.reason,
  });

  factory JobTimeSegment.fromJson(Map<String, dynamic> json) => JobTimeSegment(
        id: _string(json['id']) ?? '',
        type: switch (json['segment_type']) {
          'customer_waiting' => TimeSegmentType.customerWaiting,
          'worker_break' => TimeSegmentType.workerBreak,
          'worker_delay' => TimeSegmentType.workerDelay,
          'system_pause' => TimeSegmentType.systemPause,
          'material_wait' => TimeSegmentType.materialWait,
          'special_tool_wait' => TimeSegmentType.specialToolWait,
          _ => TimeSegmentType.working,
        },
        startedAt: _dateTime(json['started_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        endedAt: _dateTime(json['ended_at']),
        reason: _string(json['reason']),
        waitingCompensation: _integer(json['waiting_compensation']),
      );

  final String id;
  final TimeSegmentType type;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? reason;
  final int waitingCompensation;

  bool get active => endedAt == null;
  Duration durationAt(DateTime now) => (endedAt ?? now).difference(startedAt);
}

class MarketplaceAdditionalWork {
  const MarketplaceAdditionalWork({
    required this.id,
    required this.description,
    required this.additionalLabour,
    required this.estimatedMinutes,
    required this.reason,
    required this.status,
    required this.expiresAt,
  });

  factory MarketplaceAdditionalWork.fromJson(Map<String, dynamic> json) =>
      MarketplaceAdditionalWork(
        id: _string(json['id']) ?? '',
        description: _string(json['description']) ?? '',
        additionalLabour: _integer(json['additional_labour']),
        estimatedMinutes: _integer(json['estimated_minutes']),
        reason: _string(json['reason']) ?? '',
        status: AdditionalWorkStatus.values.firstWhere(
          (status) => status.name == json['status'],
          orElse: () => AdditionalWorkStatus.pending,
        ),
        expiresAt: _dateTime(json['expires_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  final String description;
  final int additionalLabour;
  final int estimatedMinutes;
  final String reason;
  final AdditionalWorkStatus status;
  final DateTime expiresAt;

  bool get actionable =>
      status == AdditionalWorkStatus.pending &&
      expiresAt.isAfter(DateTime.now());
}

class ScopeVersion {
  const ScopeVersion({
    required this.version,
    required this.items,
    required this.priceDifference,
    required this.createdAt,
  });

  factory ScopeVersion.fromJson(Map<String, dynamic> json) => ScopeVersion(
        version: _integer(json['version']),
        items: _maps(json['scope'])
            .map((item) => _string(item['label']) ?? '')
            .where((label) => label.isNotEmpty)
            .toList(),
        priceDifference: _integer(json['price_difference']),
        createdAt: _dateTime(json['created_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final int version;
  final List<String> items;
  final int priceDifference;
  final DateTime createdAt;
}

class MarketplaceEvidence {
  const MarketplaceEvidence({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.uri,
    this.note,
  });

  factory MarketplaceEvidence.fromJson(Map<String, dynamic> json) =>
      MarketplaceEvidence(
        id: _string(json['id']) ?? '',
        kind: _string(json['kind']) ?? '',
        uri: _string(json['uri']),
        note: _string(json['note']),
        createdAt: _dateTime(json['created_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  final String kind;
  final String? uri;
  final String? note;
  final DateTime createdAt;
}

class MarketplacePayment {
  const MarketplacePayment({
    required this.id,
    required this.status,
    required this.originalLabour,
    required this.approvedAdditionalLabour,
    required this.waitingCompensation,
    required this.finalLabour,
    required this.financialHold,
    this.visitFeeMinor,
    this.customerLabourMinor,
    this.finalCustomerAmountMinor,
    this.customerAmountDueMinor,
    this.workerPayoutMinor,
    this.platformMarginMinor,
    this.verifiedMinutes,
    this.approvedOvertimeMinutes,
    this.visitFeePaid = false,
    this.pricingVersion,
  });

  factory MarketplacePayment.fromJson(Map<String, dynamic> json) =>
      MarketplacePayment(
        id: _string(json['id']) ?? '',
        status: MarketplacePaymentStatus.values.firstWhere(
          (status) => _snake(status.name) == json['status'],
          orElse: () => MarketplacePaymentStatus.pending,
        ),
        originalLabour: _integer(json['original_labour']),
        approvedAdditionalLabour: _integer(json['approved_additional_labour']),
        waitingCompensation: _integer(json['waiting_compensation']),
        finalLabour: _integer(json['final_labour']),
        financialHold: json['financial_hold'] == true,
        visitFeeMinor: _nullableInteger(json['visit_fee_minor']),
        customerLabourMinor: _nullableInteger(json['customer_labour_minor']),
        finalCustomerAmountMinor:
            _nullableInteger(json['final_customer_amount_minor']),
        customerAmountDueMinor:
            _nullableInteger(json['customer_amount_due_minor']),
        workerPayoutMinor: _nullableInteger(json['worker_payout_minor']),
        platformMarginMinor: _nullableInteger(json['platform_margin_minor']),
        verifiedMinutes: _nullableInteger(json['verified_minutes']),
        approvedOvertimeMinutes:
            _nullableInteger(json['approved_overtime_minutes']),
        visitFeePaid: json['visit_fee_paid'] == true,
        pricingVersion: _string(json['pricing_version']),
      );

  final String id;
  final MarketplacePaymentStatus status;
  final int originalLabour;
  final int approvedAdditionalLabour;
  final int waitingCompensation;
  final int finalLabour;
  final bool financialHold;
  final int? visitFeeMinor;
  final int? customerLabourMinor;
  final int? finalCustomerAmountMinor;
  final int? customerAmountDueMinor;
  final int? workerPayoutMinor;
  final int? platformMarginMinor;
  final int? verifiedMinutes;
  final int? approvedOvertimeMinutes;
  final bool visitFeePaid;
  final String? pricingVersion;

  int get compatibleFinalAmountMinor =>
      finalCustomerAmountMinor ?? finalLabour * 100;
}

class MarketplaceEvent {
  const MarketplaceEvent({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.metadata,
  });

  factory MarketplaceEvent.fromJson(Map<String, dynamic> json) =>
      MarketplaceEvent(
        id: _string(json['id']) ?? '',
        type: _string(json['eventType'] ?? json['event_type']) ?? '',
        createdAt: _dateTime(json['createdAt'] ?? json['created_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        metadata: _map(json['metadata']),
      );

  final String id;
  final String type;
  final DateTime createdAt;
  final Map<String, dynamic> metadata;
}

class MarketplaceTransaction {
  const MarketplaceTransaction({
    required this.jobId,
    required this.customerTaskId,
    required this.status,
    required this.originalLabour,
    required this.currentLabour,
    required this.financialHold,
    required this.requirements,
    required this.timeSegments,
    required this.additionalWork,
    required this.scopeVersions,
    required this.completionEvidence,
    required this.disputes,
    required this.safetyEvents,
    required this.events,
    this.payment,
    this.ratingSubmitted = false,
  });

  factory MarketplaceTransaction.fromJson(Map<String, dynamic> json) {
    final job = _map(json['job']);
    return MarketplaceTransaction(
      jobId: _string(job['id']) ?? '',
      customerTaskId: _string(job['customerTaskId']) ?? '',
      status: _string(job['status']) ?? '',
      originalLabour: _integer(job['originalLabour']),
      currentLabour: _integer(job['currentLabour']),
      financialHold: job['financialHold'] == true,
      requirements:
          _maps(json['requirements']).map(JobRequirement.fromJson).toList(),
      timeSegments:
          _maps(json['timeSegments']).map(JobTimeSegment.fromJson).toList(),
      additionalWork: _maps(json['additionalWork'])
          .map(MarketplaceAdditionalWork.fromJson)
          .toList(),
      scopeVersions:
          _maps(json['scopeVersions']).map(ScopeVersion.fromJson).toList(),
      completionEvidence: _maps(json['completionEvidence'])
          .map(MarketplaceEvidence.fromJson)
          .toList(),
      disputes: _maps(json['disputes']),
      safetyEvents: _maps(json['safetyEvents']),
      payment: json['payment'] is Map
          ? MarketplacePayment.fromJson(_map(json['payment']))
          : null,
      ratingSubmitted: json['rating'] is Map,
      events: _maps(json['events']).map(MarketplaceEvent.fromJson).toList(),
    );
  }

  final String jobId;
  final String customerTaskId;
  final String status;
  final int originalLabour;
  final int currentLabour;
  final bool financialHold;
  final List<JobRequirement> requirements;
  final List<JobTimeSegment> timeSegments;
  final List<MarketplaceAdditionalWork> additionalWork;
  final List<ScopeVersion> scopeVersions;
  final List<MarketplaceEvidence> completionEvidence;
  final List<Map<String, dynamic>> disputes;
  final List<Map<String, dynamic>> safetyEvents;
  final MarketplacePayment? payment;
  final bool ratingSubmitted;
  final List<MarketplaceEvent> events;

  JobTimeSegment? get activeSegment =>
      timeSegments.where((segment) => segment.active).firstOrNull;
  List<MarketplaceAdditionalWork> get pendingAdditionalWork => additionalWork
      .where((request) => request.status == AdditionalWorkStatus.pending)
      .toList();
}

String _snake(String value) => value.replaceAllMapped(
    RegExp(r'([A-Z])'), (match) => '_${match.group(1)!.toLowerCase()}');

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
