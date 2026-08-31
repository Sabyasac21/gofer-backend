import '../domain/marketplace_transaction.dart';
import '../models/taskr_models.dart';
import '../services/customer_api_service.dart';

class CustomerBackendCapabilities {
  const CustomerBackendCapabilities({
    required this.bookingIdempotency,
    required this.workerDispatch,
    required this.workerArrival,
    required this.jobStart,
    required this.completionConfirmation,
    required this.materialRequirements,
    required this.specialTools,
    required this.waitingSessions,
    required this.additionalWork,
    required this.disputes,
    required this.payments,
    required this.ratings,
    required this.safetyCases,
  });

  static const current = CustomerBackendCapabilities(
    bookingIdempotency: true,
    workerDispatch: true,
    workerArrival: true,
    jobStart: true,
    completionConfirmation: true,
    materialRequirements: true,
    specialTools: true,
    waitingSessions: true,
    additionalWork: true,
    disputes: true,
    payments: true,
    ratings: true,
    safetyCases: true,
  );

  final bool bookingIdempotency;
  final bool workerDispatch;
  final bool workerArrival;
  final bool jobStart;
  final bool completionConfirmation;
  final bool materialRequirements;
  final bool specialTools;
  final bool waitingSessions;
  final bool additionalWork;
  final bool disputes;
  final bool payments;
  final bool ratings;
  final bool safetyCases;
}

class CustomerFeatureUnavailableException implements Exception {
  const CustomerFeatureUnavailableException(this.feature);

  final String feature;

  @override
  String toString() => '$feature is not supported by the current backend.';
}

abstract interface class CustomerJobRepository {
  CustomerBackendCapabilities get capabilities;

  Future<List<TaskRequest>> tasks();

  Future<TaskRequest> createTask({
    required ServiceCategory category,
    required String title,
    required String description,
    required String location,
    required double latitude,
    required double longitude,
    required TaskUrgency urgency,
    DateTime? scheduledAt,
    required int budget,
    String? serviceType,
    String? helperCategory,
    String? professionalCategory,
    String? serviceId,
    String? capabilityKey,
    List<String> eligibleWorkerCategories = const [],
    int? estimatedMinPrice,
    int? estimatedMaxPrice,
    String? expectedDuration,
    int? estimatedDurationMinutes,
    Map<String, Object>? pricingSnapshot,
    String? notes,
    String? workCondition,
    String? quoteId,
    String? idempotencyKey,
  });

  Future<void> ensureDispatch(TaskRequest task);

  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId);

  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  });

  Future<void> updateDispatchStatus(String customerTaskId, String status);

  Future<MarketplaceTransaction> marketplaceTransaction(String customerTaskId);

  Future<void> updateRequirement({
    required String customerTaskId,
    required String requestId,
    required RequirementStatus status,
    required String idempotencyKey,
  });

  Future<void> decideAdditionalWork({
    required String customerTaskId,
    required String requestId,
    required AdditionalWorkStatus decision,
    required String idempotencyKey,
  });

  Future<void> reportRemainingWork({
    required String customerTaskId,
    required String description,
    required String idempotencyKey,
  });

  Future<void> createCase({
    required String customerTaskId,
    required String caseType,
    required String category,
    required String description,
    required String idempotencyKey,
  });

  Future<void> confirmCompletion({
    required String customerTaskId,
    required String idempotencyKey,
  });

  Future<Map<String, dynamic>> createPaymentAttempt({
    required String customerTaskId,
    required String idempotencyKey,
  });

  Future<void> submitRating({
    required String customerTaskId,
    required int quality,
    required int professionalism,
    required int punctuality,
    required int communication,
    required String idempotencyKey,
    String? comment,
  });
}

class ApiCustomerJobRepository implements CustomerJobRepository {
  ApiCustomerJobRepository({CustomerApiService? api})
      : _api = api ?? CustomerApiService();

  final CustomerApiService _api;

  @override
  CustomerBackendCapabilities get capabilities =>
      CustomerBackendCapabilities.current;

  @override
  Future<List<TaskRequest>> tasks() => _api.tasks();

  @override
  Future<TaskRequest> createTask({
    required ServiceCategory category,
    required String title,
    required String description,
    required String location,
    required double latitude,
    required double longitude,
    required TaskUrgency urgency,
    DateTime? scheduledAt,
    required int budget,
    String? serviceType,
    String? helperCategory,
    String? professionalCategory,
    String? serviceId,
    String? capabilityKey,
    List<String> eligibleWorkerCategories = const [],
    int? estimatedMinPrice,
    int? estimatedMaxPrice,
    String? expectedDuration,
    int? estimatedDurationMinutes,
    Map<String, Object>? pricingSnapshot,
    String? notes,
    String? workCondition,
    String? quoteId,
    String? idempotencyKey,
  }) =>
      _api.createTask(
        category: category,
        title: title,
        description: description,
        location: location,
        latitude: latitude,
        longitude: longitude,
        urgency: urgency,
        scheduledAt: scheduledAt,
        budget: budget,
        serviceType: serviceType,
        helperCategory: helperCategory,
        professionalCategory: professionalCategory,
        serviceId: serviceId,
        capabilityKey: capabilityKey,
        eligibleWorkerCategories: eligibleWorkerCategories,
        estimatedMinPrice: estimatedMinPrice,
        estimatedMaxPrice: estimatedMaxPrice,
        expectedDuration: expectedDuration,
        estimatedDurationMinutes: estimatedDurationMinutes,
        pricingSnapshot: pricingSnapshot,
        notes: notes,
        workCondition: workCondition,
        quoteId: quoteId,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> ensureDispatch(TaskRequest task) => _api.ensureDispatch(task);

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) =>
      _api.dispatchStatus(customerTaskId);

  @override
  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) =>
      _api.updateTaskStatus(task, status, workerId: workerId);

  @override
  Future<void> updateDispatchStatus(String customerTaskId, String status) =>
      _api.updateDispatchStatus(customerTaskId, status);

  @override
  Future<MarketplaceTransaction> marketplaceTransaction(
    String customerTaskId,
  ) =>
      _api.marketplaceTransaction(customerTaskId);

  @override
  Future<void> updateRequirement({
    required String customerTaskId,
    required String requestId,
    required RequirementStatus status,
    required String idempotencyKey,
  }) =>
      _api.updateRequirement(
        customerTaskId: customerTaskId,
        requirementId: requestId,
        status: status,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> decideAdditionalWork({
    required String customerTaskId,
    required String requestId,
    required AdditionalWorkStatus decision,
    required String idempotencyKey,
  }) =>
      _api.decideMarketplaceAdditionalWork(
        customerTaskId: customerTaskId,
        requestId: requestId,
        decision: decision,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> reportRemainingWork({
    required String customerTaskId,
    required String description,
    required String idempotencyKey,
  }) =>
      _api.reportRemainingWork(
        customerTaskId: customerTaskId,
        description: description,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> createCase({
    required String customerTaskId,
    required String caseType,
    required String category,
    required String description,
    required String idempotencyKey,
  }) =>
      _api.createMarketplaceCase(
        customerTaskId: customerTaskId,
        caseType: caseType,
        category: category,
        description: description,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> confirmCompletion({
    required String customerTaskId,
    required String idempotencyKey,
  }) =>
      _api.confirmMarketplaceCompletion(
        customerTaskId: customerTaskId,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<Map<String, dynamic>> createPaymentAttempt({
    required String customerTaskId,
    required String idempotencyKey,
  }) =>
      _api.createPaymentAttempt(
        customerTaskId: customerTaskId,
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<void> submitRating({
    required String customerTaskId,
    required int quality,
    required int professionalism,
    required int punctuality,
    required int communication,
    required String idempotencyKey,
    String? comment,
  }) =>
      _api.submitMarketplaceRating(
        customerTaskId: customerTaskId,
        quality: quality,
        professionalism: professionalism,
        punctuality: punctuality,
        communication: communication,
        idempotencyKey: idempotencyKey,
        comment: comment,
      );
}
