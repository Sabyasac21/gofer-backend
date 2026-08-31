enum WorkforceCategory { helper, professional }

enum JobPricingType { fixedLabour, estimatedLabour, inspection }

enum JobQuestionType {
  singleChoice,
  multiChoice,
  number,
  shortText,
  longText,
  yesNo,
}

class JobQuestionOption {
  const JobQuestionOption({required this.value, required this.label});

  final String value;
  final String label;
}

class JobQuestionDefinition {
  const JobQuestionDefinition({
    required this.id,
    required this.prompt,
    required this.type,
    this.required = false,
    this.helperText,
    this.options = const [],
    this.min,
    this.max,
    this.suffix,
  });

  final String id;
  final String prompt;
  final JobQuestionType type;
  final bool required;
  final String? helperText;
  final List<JobQuestionOption> options;
  final num? min;
  final num? max;
  final String? suffix;
}

class LabourPriceDefinition {
  const LabourPriceDefinition._({
    required this.type,
    this.fixedAmount,
    this.minimumAmount,
    this.maximumAmount,
    this.inspectionAmount,
    required this.explanation,
  });

  const LabourPriceDefinition.fixed({
    required int amount,
    required String explanation,
  }) : this._(
          type: JobPricingType.fixedLabour,
          fixedAmount: amount,
          explanation: explanation,
        );

  const LabourPriceDefinition.estimated({
    required int minimum,
    required int maximum,
    required String explanation,
  }) : this._(
          type: JobPricingType.estimatedLabour,
          minimumAmount: minimum,
          maximumAmount: maximum,
          explanation: explanation,
        );

  const LabourPriceDefinition.inspection({
    required int visitAmount,
    required String explanation,
  }) : this._(
          type: JobPricingType.inspection,
          inspectionAmount: visitAmount,
          explanation: explanation,
        );

  final JobPricingType type;
  final int? fixedAmount;
  final int? minimumAmount;
  final int? maximumAmount;
  final int? inspectionAmount;
  final String explanation;

  int get bookingAmount => switch (type) {
        JobPricingType.fixedLabour => fixedAmount!,
        JobPricingType.estimatedLabour => maximumAmount!,
        JobPricingType.inspection => inspectionAmount!,
      };

  int get minimumBookingAmount => switch (type) {
        JobPricingType.fixedLabour => fixedAmount!,
        JobPricingType.estimatedLabour => minimumAmount!,
        JobPricingType.inspection => inspectionAmount!,
      };

  String get label => switch (type) {
        JobPricingType.fixedLabour => '₹$fixedAmount labour',
        JobPricingType.estimatedLabour =>
          '₹$minimumAmount–₹$maximumAmount estimated labour',
        JobPricingType.inspection => '₹$inspectionAmount inspection labour',
      };
}

class JobTemplate {
  const JobTemplate({
    required this.id,
    required this.serviceId,
    required this.workforceCategory,
    required this.name,
    required this.description,
    required this.questions,
    required this.pricing,
    required this.estimatedDuration,
    required this.requiredWorkerSkills,
    this.requiredWorkerTools = const [],
    this.customerProvidedMaterials = const [],
    this.photoRecommended = false,
    this.photoRequired = false,
    this.locationRequired = true,
    this.schedulingRequired = true,
    this.inspectionRequired = false,
    this.additionalWorkAllowed = true,
    this.beforeAfterEvidenceRecommended = false,
  });

  final String id;
  final String serviceId;
  final WorkforceCategory workforceCategory;
  final String name;
  final String description;
  final List<JobQuestionDefinition> questions;
  final LabourPriceDefinition pricing;
  final String estimatedDuration;
  final List<String> requiredWorkerSkills;
  final List<String> requiredWorkerTools;
  final List<String> customerProvidedMaterials;
  final bool photoRecommended;
  final bool photoRequired;
  final bool locationRequired;
  final bool schedulingRequired;
  final bool inspectionRequired;
  final bool additionalWorkAllowed;
  final bool beforeAfterEvidenceRecommended;
}

class ServiceDefinition {
  const ServiceDefinition({
    required this.id,
    required this.domainId,
    required this.name,
    required this.shortDescription,
    required this.searchTerms,
    required this.template,
    this.collectionId,
    this.imageAsset,
    this.isFeatured = false,
    this.badge,
    this.capabilityKey,
    this.workerCategories = const [],
    this.legacyIds = const [],
    this.active = true,
    this.sortOrder = 0,
  });

  final String id;
  final String domainId;
  final String name;
  final String shortDescription;
  final List<String> searchTerms;
  final JobTemplate template;
  final String? collectionId;
  final String? imageAsset;
  final bool isFeatured;
  final String? badge;

  /// Stable machine-readable skill used by dispatch. Display names must never
  /// be used as capability identifiers.
  final String? capabilityKey;

  /// Existing worker profession declarations that qualify for this skill.
  final List<String> workerCategories;

  /// Historical service IDs that resolve to this canonical definition.
  final List<String> legacyIds;
  final bool active;
  final int sortOrder;
}

class ServiceCollectionDefinition {
  const ServiceCollectionDefinition({
    required this.id,
    required this.domainId,
    required this.name,
    required this.description,
    this.sortOrder = 0,
  });

  final String id;
  final String domainId;
  final String name;
  final String description;
  final int sortOrder;
}

class ServiceDomainDefinition {
  const ServiceDomainDefinition({
    required this.id,
    required this.workforceCategory,
    required this.name,
    required this.description,
    this.imageAsset,
  });

  final String id;
  final WorkforceCategory workforceCategory;
  final String name;
  final String description;
  final String? imageAsset;
}

class ServiceCatalog {
  const ServiceCatalog({
    required this.domains,
    required this.services,
    this.collections = const [],
  });

  final List<ServiceDomainDefinition> domains;
  final List<ServiceDefinition> services;
  final List<ServiceCollectionDefinition> collections;

  List<ServiceDomainDefinition> domainsFor(WorkforceCategory category) =>
      domains
          .where((domain) => domain.workforceCategory == category)
          .toList(growable: false);

  List<ServiceDefinition> servicesForDomain(String domainId) => services
      .where((service) => service.domainId == domainId && service.active)
      .toList(growable: false)
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<ServiceCollectionDefinition> collectionsForDomain(String domainId) =>
      collections
          .where((collection) => collection.domainId == domainId)
          .toList(growable: false)
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<ServiceDefinition> servicesForCollection(String collectionId) => services
      .where(
          (service) => service.collectionId == collectionId && service.active)
      .toList(growable: false)
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  ServiceDefinition? serviceById(String serviceId) {
    for (final service in services) {
      if (service.active &&
          (service.id == serviceId || service.legacyIds.contains(serviceId))) {
        return service;
      }
    }
    for (final service in services) {
      if (service.id == serviceId) return service;
    }
    return null;
  }

  ServiceCatalog withRemoteServices(List<Map<String, dynamic>> remote) {
    final byId = {for (final service in services) service.id: service};
    for (final json in remote) {
      final id = json['serviceId'] as String?;
      if (id == null || id.isEmpty) continue;
      final bundled = byId[id];
      if (bundled != null) {
        byId[id] = _copyService(
          bundled,
          active: json['active'] as bool? ?? true,
        );
        continue;
      }
      final created = _remoteService(json);
      if (created != null) byId[id] = created;
    }
    return ServiceCatalog(
      domains: domains,
      collections: collections,
      services: byId.values.toList(growable: false),
    );
  }
}

ServiceDefinition _copyService(ServiceDefinition service,
        {required bool active}) =>
    ServiceDefinition(
      id: service.id,
      domainId: service.domainId,
      name: service.name,
      shortDescription: service.shortDescription,
      searchTerms: service.searchTerms,
      template: service.template,
      collectionId: service.collectionId,
      imageAsset: service.imageAsset,
      isFeatured: service.isFeatured,
      badge: service.badge,
      capabilityKey: service.capabilityKey,
      workerCategories: service.workerCategories,
      legacyIds: service.legacyIds,
      active: active,
      sortOrder: service.sortOrder,
    );

ServiceDefinition? _remoteService(Map<String, dynamic> json) {
  final catalog = json['catalog'];
  if (catalog is! Map) return null;
  final data = Map<String, dynamic>.from(catalog);
  final templateData = data['template'];
  if (templateData is! Map) return null;
  final template = Map<String, dynamic>.from(templateData);
  final serviceId = json['serviceId'] as String? ?? '';
  final serviceName = json['serviceName'] as String? ?? '';
  final workforce = _enumByName(
    WorkforceCategory.values,
    template['workforceCategory'],
    WorkforceCategory.professional,
  );
  final model = json['pricingModel'] as String? ?? 'fixed';
  final amount = ((json['basePriceMinor'] as num?)?.toInt() ?? 0) ~/ 100;
  final visit = ((json['visitFeeMinor'] as num?)?.toInt() ?? 0) ~/ 100;
  final pricing = model == 'inspection' || model == 'quote'
      ? LabourPriceDefinition.inspection(
          visitAmount: visit,
          explanation: 'Admin-managed service pricing.',
        )
      : LabourPriceDefinition.fixed(
          amount: amount,
          explanation: 'Admin-managed service pricing.',
        );
  return ServiceDefinition(
    id: serviceId,
    domainId: data['domainId'] as String? ?? '',
    name: serviceName,
    shortDescription: data['shortDescription'] as String? ?? serviceName,
    searchTerms: _strings(data['searchTerms']),
    collectionId: data['collectionId'] as String?,
    imageAsset: data['imageAsset'] as String?,
    isFeatured: data['isFeatured'] as bool? ?? false,
    badge: data['badge'] as String?,
    capabilityKey: data['capabilityKey'] as String?,
    workerCategories: _strings(data['workerCategories']),
    active: json['active'] as bool? ?? false,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? 0,
    template: JobTemplate(
      id: template['id'] as String? ?? '${serviceId}_template',
      serviceId: serviceId,
      workforceCategory: workforce,
      name: serviceName,
      description: template['description'] as String? ?? serviceName,
      questions: _remoteQuestions(template['questions']),
      pricing: pricing,
      estimatedDuration: template['estimatedDuration'] as String? ?? 'Varies',
      requiredWorkerSkills: _strings(template['requiredWorkerSkills']),
      requiredWorkerTools: _strings(template['requiredWorkerTools']),
      customerProvidedMaterials:
          _strings(template['customerProvidedMaterials']),
      photoRecommended: template['photoRecommended'] as bool? ?? false,
      photoRequired: template['photoRequired'] as bool? ?? false,
      locationRequired: template['locationRequired'] as bool? ?? true,
      schedulingRequired: template['schedulingRequired'] as bool? ?? true,
      inspectionRequired: template['inspectionRequired'] as bool? ?? false,
      additionalWorkAllowed: template['additionalWorkAllowed'] as bool? ?? true,
      beforeAfterEvidenceRecommended:
          template['beforeAfterEvidenceRecommended'] as bool? ?? false,
    ),
  );
}

List<JobQuestionDefinition> _remoteQuestions(Object? value) => value is List
    ? value.whereType<Map>().map((raw) {
        final item = Map<String, dynamic>.from(raw);
        return JobQuestionDefinition(
          id: item['id'] as String? ?? '',
          prompt: item['prompt'] as String? ?? '',
          type: _enumByName(
            JobQuestionType.values,
            item['type'],
            JobQuestionType.shortText,
          ),
          required: item['required'] as bool? ?? false,
          helperText: item['helperText'] as String?,
          min: item['min'] as num?,
          max: item['max'] as num?,
          suffix: item['suffix'] as String?,
          options: item['options'] is List
              ? (item['options'] as List)
                  .whereType<Map>()
                  .map((option) => JobQuestionOption(
                        value: option['value'] as String? ?? '',
                        label: option['label'] as String? ?? '',
                      ))
                  .toList(growable: false)
              : const [],
        );
      }).toList(growable: false)
    : const [];

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((value) => value.name == name).firstOrNull ?? fallback;

class ServiceClassification {
  const ServiceClassification({
    required this.query,
    required this.service,
    required this.confidence,
    this.missingInformation = const [],
    this.extractedAnswers = const {},
  });

  final String query;
  final ServiceDefinition service;
  final double confidence;
  final List<String> missingInformation;
  final Map<String, Object> extractedAnswers;
}

abstract interface class ServiceClassifier {
  List<ServiceClassification> classify(String problem, {int limit = 3});
}
