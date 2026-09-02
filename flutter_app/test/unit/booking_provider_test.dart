import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:gofer/data/sample_data.dart';
import 'package:gofer/domain/job_lifecycle.dart';
import 'package:gofer/domain/marketplace_transaction.dart';
import 'package:gofer/models/taskr_models.dart';
import 'package:gofer/providers/booking_provider.dart';
import 'package:gofer/services/customer_api_service.dart';

class _FailingCustomerApiService extends CustomerApiService {
  @override
  Future<List<TaskRequest>> tasks() async => const [];

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
  }) async {
    throw const CustomerApiException('Backend unavailable.');
  }
}

class _SlowCustomerApiService extends CustomerApiService {
  final releaseCreate = Completer<void>();
  int createCalls = 0;
  String? receivedIdempotencyKey;

  @override
  Future<List<TaskRequest>> tasks() async => const [];

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
  }) async {
    createCalls += 1;
    receivedIdempotencyKey = idempotencyKey;
    await releaseCreate.future;
    return TaskRequest(
      id: 'task-idempotent',
      category: category,
      title: title,
      description: description,
      location: location,
      urgency: urgency,
      budget: budget,
      status: TaskStatus.broadcasting,
    );
  }

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async =>
      const CustomerDispatchStatus(status: 'offered', offerCount: 0);
}

class _CompletionCustomerApiService extends CustomerApiService {
  _CompletionCustomerApiService({
    this.failCompletion = false,
  });

  String dispatchState = 'completion_requested';
  final bool failCompletion;
  final List<String> dispatchUpdates = [];
  final List<TaskStatus> taskUpdates = [];

  TaskRequest get activeTask => TaskRequest(
        id: 'e9476f50-6d80-4458-b5f6-7cad8c5f1aeb',
        category: serviceCategories.first,
        title: 'Cleaning',
        description: 'Clean the room',
        location: 'Current location',
        urgency: TaskUrgency.now,
        budget: 179,
        status: TaskStatus.workerSelected,
      );

  @override
  Future<List<TaskRequest>> tasks() async => [activeTask];

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async {
    return CustomerDispatchStatus(
      status: dispatchState,
      offerCount: 1,
      worker: const WorkerProfile(
        id: 'worker-1',
        name: 'Sabyasachi Nishant',
        skill: 'Cleaning',
        rating: 5,
        jobsCompleted: 1,
        distanceKm: 0,
        etaMinutes: 0,
        hourlyRate: 179,
        verified: true,
        initials: 'SN',
      ),
    );
  }

  @override
  Future<void> updateDispatchStatus(
    String customerTaskId,
    String status,
  ) async {
    dispatchUpdates.add(status);
    if (failCompletion) {
      throw const CustomerApiException(
        'Active dispatch not found',
        statusCode: 404,
      );
    }
    dispatchState = status;
  }

  @override
  Future<void> confirmMarketplaceCompletion({
    required String customerTaskId,
    required String idempotencyKey,
  }) async {
    dispatchUpdates.add('completed');
    if (failCompletion) {
      throw const CustomerApiException(
        'Active dispatch not found',
        statusCode: 404,
      );
    }
    dispatchState = 'completed';
  }

  @override
  Future<void> reportRemainingWork({
    required String customerTaskId,
    required String description,
    required String idempotencyKey,
    List<String> evidence = const [],
  }) async {
    dispatchUpdates.add('started');
    dispatchState = 'started';
  }

  @override
  Future<MarketplaceTransaction> marketplaceTransaction(
    String customerTaskId,
  ) async =>
      MarketplaceTransaction(
        jobId: 'dispatch-1',
        customerTaskId: customerTaskId,
        status: dispatchState,
        originalLabour: 179,
        currentLabour: 179,
        financialHold: false,
        requirements: const [],
        timeSegments: const [],
        additionalWork: const [],
        scopeVersions: const [],
        completionEvidence: const [],
        disputes: const [],
        safetyEvents: const [],
        events: const [],
        payment: dispatchState == 'completed'
            ? const MarketplacePayment(
                id: 'payment-1',
                status: MarketplacePaymentStatus.pending,
                originalLabour: 179,
                approvedAdditionalLabour: 0,
                waitingCompensation: 0,
                finalLabour: 179,
                financialHold: false,
              )
            : null,
      );

  @override
  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) async {
    taskUpdates.add(status);
    return task.copyWith(status: status);
  }
}

class _SlowCompletionCustomerApiService extends _CompletionCustomerApiService {
  final releaseCompletion = Completer<void>();

  @override
  Future<void> confirmMarketplaceCompletion({
    required String customerTaskId,
    required String idempotencyKey,
  }) async {
    dispatchUpdates.add('completed');
    await releaseCompletion.future;
    dispatchState = 'completed';
  }
}

class _NoWorkerCustomerApiService extends CustomerApiService {
  TaskRequest get task => TaskRequest(
        id: 'e9476f50-6d80-4458-b5f6-7cad8c5f1aeb',
        category: serviceCategories.first,
        title: 'Cleaning',
        description: 'Clean the room',
        location: 'Current location',
        urgency: TaskUrgency.now,
        budget: 179,
        status: TaskStatus.broadcasting,
      );

  @override
  Future<List<TaskRequest>> tasks() async => [task];

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async =>
      const CustomerDispatchStatus(status: 'expired', offerCount: 0);

  @override
  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) async =>
      task.copyWith(status: status);
}

class _ReplacementCustomerApiService extends CustomerApiService {
  final List<TaskStatus> taskUpdates = [];

  final worker = const WorkerProfile(
    id: 'worker-1',
    name: 'Assigned Worker',
    skill: 'Cleaning',
    rating: 5,
    jobsCompleted: 1,
    distanceKm: 0,
    etaMinutes: 0,
    hourlyRate: 179,
    verified: true,
    initials: 'AW',
  );

  late final TaskRequest task = TaskRequest(
    id: 'e9476f50-6d80-4458-b5f6-7cad8c5f1aeb',
    category: serviceCategories.first,
    title: 'Cleaning',
    description: 'Clean the room',
    location: 'Current location',
    urgency: TaskUrgency.now,
    budget: 179,
    status: TaskStatus.workerSelected,
    selectedOffer: WorkerOffer(
      worker: worker,
      quote: 179,
      message: 'Accepted',
      receivedSecondsAgo: 0,
    ),
  );

  @override
  Future<List<TaskRequest>> tasks() async => [task];

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async {
    return const CustomerDispatchStatus(
      status: 'offered',
      offerCount: 1,
      worker: null,
    );
  }

  @override
  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) async {
    taskUpdates.add(status);
    return task.copyWith(status: status);
  }
}

class _RestoredReplacementCustomerApiService
    extends _ReplacementCustomerApiService {
  @override
  Future<List<TaskRequest>> tasks() async => [
        task.copyWith(clearSelectedOffer: true),
      ];
}

class _CancellationCustomerApiService extends CustomerApiService {
  _CancellationCustomerApiService({
    this.failDispatchCancellation = false,
  });

  final bool failDispatchCancellation;
  final List<String> dispatchUpdates = [];
  final List<TaskStatus> taskUpdates = [];

  TaskRequest get task => TaskRequest(
        id: 'e9476f50-6d80-4458-b5f6-7cad8c5f1aeb',
        category: serviceCategories.first,
        title: 'Cleaning',
        description: 'Clean the room',
        location: 'Current location',
        urgency: TaskUrgency.now,
        budget: 179,
        status: TaskStatus.broadcasting,
      );

  @override
  Future<List<TaskRequest>> tasks() async => [task];

  @override
  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async {
    return const CustomerDispatchStatus(
      status: 'offered',
      offerCount: 2,
    );
  }

  @override
  Future<void> updateDispatchStatus(
    String customerTaskId,
    String status,
  ) async {
    dispatchUpdates.add(status);
    if (failDispatchCancellation) {
      throw const CustomerApiException(
        'Worker cancellation broadcast unavailable',
        statusCode: 503,
      );
    }
  }

  @override
  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) async {
    taskUpdates.add(status);
    return task.copyWith(status: status);
  }
}

void main() {
  test('concurrent submit taps create one idempotent booking', () async {
    final api = _SlowCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    Future<void> submit() => controller.submitTask(
          category: serviceCategories.first,
          title: 'Cleaning',
          description: 'Clean one room',
          location: 'Current location',
          urgency: TaskUrgency.now,
          budget: 179,
          idempotencyKey: '3a497694-25fd-4f3f-87d8-8a20991f364c',
        );

    final first = submit();
    await Future<void>.delayed(Duration.zero);
    final second = submit();
    api.releaseCreate.complete();
    await Future.wait([first, second]);

    expect(api.createCalls, 1);
    expect(
      api.receivedIdempotencyKey,
      '3a497694-25fd-4f3f-87d8-8a20991f364c',
    );
    expect(controller.state.activeRequest?.id, 'task-idempotent');
  });

  test('failed task submission remains fail-closed without a fake booking',
      () async {
    final controller = BookingController(api: _FailingCustomerApiService());
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    await controller.submitTask(
      category:
          serviceCategories.firstWhere((category) => category.id == 'labour'),
      title: 'Packing helper',
      description: 'Need help with packing.',
      location: 'Current location',
      urgency: TaskUrgency.now,
      budget: 718,
      workerType: WorkerType.helper,
      helperCategory: 'Packing',
      expectedDuration: 'Half Day',
    );

    expect(controller.state.isLoading, isFalse);
    expect(controller.state.activeRequest, isNull);
    expect(controller.state.offers, isEmpty);
    expect(controller.state.errorMessage, 'Backend unavailable.');
  });

  test('worker completion request asks the customer for confirmation',
      () async {
    final api = _CompletionCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.activeRequest, isNotNull);
    expect(controller.state.completionConfirmationPending, isTrue);
    expect(controller.state.completedRequests, isEmpty);
  });

  test('customer approval completes dispatch and task exactly once', () async {
    final api = _CompletionCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.completeActiveBooking();

    expect(api.dispatchUpdates, ['completed']);
    expect(api.taskUpdates, contains(TaskStatus.completed));
    expect(controller.state.activeRequest?.status, TaskStatus.completed);
    expect(controller.state.completedRequests, hasLength(1));
    expect(controller.state.lifecycleStatus, JobStatus.paymentPending);
  });

  test('duplicate completion taps produce one backend confirmation', () async {
    final api = _SlowCompletionCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final first = controller.completeActiveBooking();
    await Future<void>.delayed(Duration.zero);
    final second = controller.completeActiveBooking();
    api.releaseCompletion.complete();
    await Future.wait([first, second]);

    expect(api.dispatchUpdates, ['completed']);
    expect(
      api.taskUpdates.where((status) => status == TaskStatus.completed),
      hasLength(1),
    );
  });

  test('expired dispatch becomes a finite no-worker state', () async {
    final controller = BookingController(api: _NoWorkerCustomerApiService());
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.lifecycleStatus, JobStatus.noWorkerAvailable);
    expect(controller.state.activeRequest?.status, TaskStatus.noWorkersFound);
    expect(controller.state.isLoading, isFalse);
  });

  test('completion failure keeps booking active for a safe retry', () async {
    final api = _CompletionCustomerApiService(failCompletion: true);
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.completeActiveBooking();

    expect(controller.state.activeRequest, isNotNull);
    expect(controller.state.completedRequests, isEmpty);
    expect(controller.state.errorMessage, contains('Active dispatch'));
  });

  test('customer can report remaining work without releasing worker', () async {
    final api = _CompletionCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.markWorkRemaining();

    expect(api.dispatchUpdates, ['started']);
    expect(controller.state.activeRequest, isNotNull);
    expect(controller.state.completionConfirmationPending, isFalse);
  });

  test('worker cancellation returns customer UI to replacement search',
      () async {
    final api = _ReplacementCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.activeRequest?.selectedOffer, isNull);
    expect(
      controller.state.activeRequest?.status,
      TaskStatus.collectingOffers,
    );
    expect(controller.state.offers, isEmpty);
    expect(controller.state.events.first.title, contains('cancelled'));
    expect(api.taskUpdates, contains(TaskStatus.collectingOffers));
  });

  test('replacement search is recovered after the customer app restarts',
      () async {
    final api = _RestoredReplacementCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.state.activeRequest?.status,
      TaskStatus.collectingOffers,
    );
    expect(controller.state.events.first.title, contains('cancelled'));
    expect(api.taskUpdates, contains(TaskStatus.collectingOffers));
  });

  test('customer cancellation clears the UI only after dispatch confirmation',
      () async {
    final api = _CancellationCustomerApiService();
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.cancelActiveBooking();

    expect(api.dispatchUpdates, ['cancelled']);
    expect(api.taskUpdates, [TaskStatus.cancelled]);
    expect(controller.state.activeRequest, isNull);
    expect(controller.state.isLoading, isFalse);
  });

  test('failed cancellation keeps the request active for a safe retry',
      () async {
    final api = _CancellationCustomerApiService(
      failDispatchCancellation: true,
    );
    final controller = BookingController(api: api);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.cancelActiveBooking();

    expect(api.dispatchUpdates, ['cancelled']);
    expect(api.taskUpdates, isEmpty);
    expect(controller.state.activeRequest, isNotNull);
    expect(controller.state.isLoading, isFalse);
    expect(controller.state.errorMessage, contains('still active'));
  });
}
