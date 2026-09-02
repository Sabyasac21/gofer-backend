import 'dart:convert';
import 'dart:io';

import 'package:gofer/data/workida_service_catalog.dart';
import 'package:gofer/domain/service_expectation.dart';

/// Copies the customer-facing service scope defaults into the shared price
/// book. Run from `flutter_app` after changing the bundled expectation copy.
void main() {
  final file = File.fromUri(
    Platform.script.resolve('../assets/config/workida-price-book.json'),
  );
  final book = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final services = (book['services'] as List).cast<Map<String, dynamic>>();

  for (final entry in services) {
    final service = workidaServiceCatalog.serviceById(
      entry['serviceId'] as String,
    );
    if (service == null) {
      stderr.writeln('No client service found for ${entry['serviceId']}');
      exitCode = 1;
      continue;
    }
    final expectation = service.id == 'household_help_session'
        ? householdHelpExpectation
        : expectationForService(service);
    entry['includedScope'] = expectation.included;
    entry['exclusions'] = expectation.notIncluded;
    entry['active'] = service.active;
    entry['catalog'] = {
      'domainId': service.domainId,
      'collectionId': service.collectionId,
      'shortDescription': service.shortDescription,
      'searchTerms': service.searchTerms,
      'imageAsset': service.imageAsset,
      'isFeatured': service.isFeatured,
      'badge': service.badge,
      'capabilityKey': service.capabilityKey,
      'workerCategories': service.workerCategories,
      'sortOrder': service.sortOrder,
      'template': {
        'id': service.template.id,
        'serviceId': service.template.serviceId,
        'workforceCategory': service.template.workforceCategory.name,
        'name': service.template.name,
        'description': service.template.description,
        'estimatedDuration': service.template.estimatedDuration,
        'requiredWorkerSkills': service.template.requiredWorkerSkills,
        'requiredWorkerTools': service.template.requiredWorkerTools,
        'customerProvidedMaterials': service.template.customerProvidedMaterials,
        'photoRecommended': service.template.photoRecommended,
        'photoRequired': service.template.photoRequired,
        'locationRequired': service.template.locationRequired,
        'schedulingRequired': service.template.schedulingRequired,
        'inspectionRequired': service.template.inspectionRequired,
        'additionalWorkAllowed': service.template.additionalWorkAllowed,
        'beforeAfterEvidenceRecommended':
            service.template.beforeAfterEvidenceRecommended,
        'questions': [
          for (final question in service.template.questions)
            {
              'id': question.id,
              'prompt': question.prompt,
              'type': question.type.name,
              'required': question.required,
              'helperText': question.helperText,
              'min': question.min,
              'max': question.max,
              'suffix': question.suffix,
              'options': [
                for (final option in question.options)
                  {'value': option.value, 'label': option.label},
              ],
            },
        ],
      },
    };
  }

  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(book)}\n',
  );
}
