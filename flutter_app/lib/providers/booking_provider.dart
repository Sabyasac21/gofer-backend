import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../domain/job_lifecycle.dart';
import '../domain/marketplace_transaction.dart';
import '../domain/pricing_engine.dart';
import '../models/taskr_models.dart';
import '../repositories/customer_job_repository.dart';
import '../services/customer_api_service.dart';
import '../services/customer_event_logger.dart';
import '../services/job_event_stream.dart';

final bookingControllerProvider =
    StateNotifierProvider<BookingController, BookingState>(
  (ref) => BookingController(),
);

class BookingController extends StateNotifier<BookingState> {
  BookingController({
    CustomerApiService? api,
    CustomerJobRepository? repository,
    CustomerEventLogger? eventLogger,
  })  : assert(api == null || repository == null),
        _repository = repository ?? ApiCustomerJobRepository(api: api),
        _eventLogger = eventLogger ?? const StructuredCustomerEventLogger(),
        super(const BookingState()) {
    _jobEventStream = PollingJobEventStream(
      load: _repository.marketplaceTransaction,
    );
    unawaited(_restoreTasks());
  }

  final CustomerJobRepository _repository;
  final CustomerEventLogger _eventLogger;
  late final JobEventStream _jobEventStream;
  StreamSubscription<MarketplaceTransaction>? _marketplaceSubscription;
  String? _marketplaceJobId;

  final List<Timer> _timers = [];
  bool _submissionInFlight = false;
  bool _completionActionInFlight = false;
  bool _cancellationInFlight = false;

  void clearError() => state = state.copyWith(clearError: true);

  Future<void> submitTask({
    required ServiceCategory category,
    required String title,
    required String description,
    required String location,
    double latitude = 28.6274,
    double longitude = 77.3723,
    required TaskUrgency urgency,
    DateTime? scheduledAt,
    required int budget,
    WorkerType? workerType,
    String? helperCategory,
    String? professionalCategory,
    String? serviceId,
    String? capabilityKey,
    List<String> eligibleWorkerCategories = const [],
    int? estimatedMinPrice,
    int? estimatedMaxPrice,
    String? expectedDuration,
    int? estimatedDurationMinutes,
    ServicePricingConfig? pricingConfig,
    Map<String, Object>? pricingSnapshot,
    String? notes,
    String? workCondition,
    String? quoteId,
    String? idempotencyKey,
  }) async {
    if (_submissionInFlight) return;
    _submissionInFlight = true;
    unawaited(_marketplaceSubscription?.cancel());
    _marketplaceSubscription = null;
    _marketplaceJobId = null;
    _cancelTimers();
    state = state.copyWith(isLoading: true, clearError: true);
    _eventLogger.log(
      CustomerOperationEvent.bookingStarted,
      attributes: {'category': category.name},
    );
    try {
      final request = await _repository.createTask(
        category: category,
        title: title,
        description: description,
        location: location,
        latitude: latitude,
        longitude: longitude,
        urgency: urgency,
        scheduledAt: scheduledAt,
        budget: budget,
        serviceType: workerType?.name,
        helperCategory: helperCategory,
        professionalCategory: professionalCategory,
        serviceId: serviceId,
        capabilityKey: capabilityKey,
        eligibleWorkerCategories: eligibleWorkerCategories,
        estimatedMinPrice: estimatedMinPrice,
        estimatedMaxPrice: estimatedMaxPrice,
        expectedDuration: expectedDuration,
        estimatedDurationMinutes: estimatedDurationMinutes,
        pricingSnapshot: pricingConfig?.toJson() ?? pricingSnapshot,
        notes: notes,
        workCondition: workCondition,
        quoteId: quoteId,
        idempotencyKey: idempotencyKey ?? const Uuid().v4(),
      );
      state = BookingState(
        activeRequest: request,
        isLoading: false,
        lifecycleStatus: JobStatus.searching,
        completedRequests: state.completedRequests,
        events: [
          BookingEvent(
            type: BookingEventType.broadcast,
            title: 'Task saved and broadcast',
            message: workerType == WorkerType.helper
                ? 'Searching verified helpers for $helperCategory.'
                : 'Searching verified ${category.name.toLowerCase()} workers.',
            timeLabel: 'now',
          ),
        ],
      );
      _eventLogger.log(
        CustomerOperationEvent.bookingCreated,
        attributes: {'jobId': request.id, 'category': category.name},
      );
      _eventLogger.log(
        CustomerOperationEvent.matchingStarted,
        attributes: {'jobId': request.id},
      );
      _watchDispatch(request);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    } finally {
      _submissionInFlight = false;
    }
  }

  Future<void> selectOffer(WorkerOffer offer) async {
    final request = state.activeRequest;
    if (request == null) return;

    state = state.copyWith(
      activeRequest: request.copyWith(
        status: TaskStatus.workerSelected,
        selectedOffer: offer,
      ),
      events: [
        BookingEvent(
          type: BookingEventType.selection,
          title: '${offer.worker.name} selected',
          message: 'Booking confirmed. Worker has received your address.',
          timeLabel: 'now',
        ),
        ...state.events,
      ],
    );

    try {
      await _repository.updateTaskStatus(
        request,
        TaskStatus.workerSelected,
        workerId: offer.worker.id,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<void> completeActiveBooking() async {
    if (_completionActionInFlight) return;
    final request = state.activeRequest;
    if (request == null) return;
    _completionActionInFlight = true;
    try {
      await _repository.confirmCompletion(
        customerTaskId: request.id,
        idempotencyKey: const Uuid().v4(),
      );
      await _repository.updateTaskStatus(request, TaskStatus.completed);
      _eventLogger.log(
        CustomerOperationEvent.completionConfirmed,
        attributes: {'jobId': request.id},
      );
      _recordCompleted(request);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    } finally {
      _completionActionInFlight = false;
    }
  }

  Future<void> markWorkRemaining([
    String description =
        'Customer reported that agreed work is still remaining.',
  ]) async {
    if (_completionActionInFlight) return;
    final request = state.activeRequest;
    if (request == null || !state.completionConfirmationPending) return;
    _completionActionInFlight = true;
    try {
      await _repository.reportRemainingWork(
        customerTaskId: request.id,
        description: description,
        idempotencyKey: const Uuid().v4(),
      );
      state = state.copyWith(
        completionConfirmationPending: false,
        clearError: true,
        events: [
          const BookingEvent(
            type: BookingEventType.workerResponse,
            title: 'Work is still in progress',
            message: 'The worker has been asked to finish the remaining work.',
            timeLabel: 'now',
          ),
          ...state.events,
        ],
      );
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    } finally {
      _completionActionInFlight = false;
    }
  }

  void _recordCompleted(TaskRequest request) {
    _cancelTimers();
    final completed = request.copyWith(status: TaskStatus.completed);
    state = state.copyWith(
      activeRequest: completed,
      offers: [],
      completionConfirmationPending: false,
      lifecycleStatus: JobStatus.paymentPending,
      completedRequests: [
        completed,
        ...state.completedRequests.where((item) => item.id != completed.id),
      ],
      events: [
        BookingEvent(
          type: BookingEventType.completion,
          title: 'Task completed',
          message: '${request.title} has been confirmed complete.',
          timeLabel: 'now',
        ),
        ...state.events,
      ],
      clearError: true,
    );
    _eventLogger.log(
      CustomerOperationEvent.jobCompleted,
      attributes: {'jobId': request.id},
    );
  }

  Future<void> cancelActiveBooking() async {
    if (_cancellationInFlight) return;
    final request = state.activeRequest;
    if (request == null) return;
    _cancellationInFlight = true;
    _cancelTimers();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _repository.updateDispatchStatus(request.id, 'cancelled');
      try {
        await _repository.updateTaskStatus(request, TaskStatus.cancelled);
      } catch (error) {
        // The worker dispatch is authoritative for stopping offers. Do not
        // revive a successfully cancelled request just because the secondary
        // task-history update is temporarily unavailable.
        state = state.copyWith(
          errorMessage:
              'The request was cancelled, but booking history could not be updated: $error',
        );
      }
      state = state.copyWith(
        clearActive: true,
        offers: const [],
        isLoading: false,
      );
      unawaited(_marketplaceSubscription?.cancel());
      _marketplaceSubscription = null;
      _marketplaceJobId = null;
      _eventLogger.log(
        CustomerOperationEvent.jobCancelled,
        attributes: {'jobId': request.id},
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            'Cancellation was not confirmed. The request is still active: $error',
      );
      _watchDispatch(request);
    } finally {
      _cancellationInFlight = false;
    }
  }

  Future<void> updateRequirement(
    JobRequirement requirement,
    RequirementStatus status,
  ) async {
    final request = state.activeRequest;
    if (request == null) return;
    try {
      await _repository.updateRequirement(
        customerTaskId: request.id,
        requestId: requirement.id,
        status: status,
        idempotencyKey: const Uuid().v4(),
      );
      await _refreshMarketplace(request);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<void> decideAdditionalWork(
    MarketplaceAdditionalWork additionalWork,
    AdditionalWorkStatus decision,
  ) async {
    final request = state.activeRequest;
    if (request == null) return;
    try {
      await _repository.decideAdditionalWork(
        customerTaskId: request.id,
        requestId: additionalWork.id,
        decision: decision,
        idempotencyKey: const Uuid().v4(),
      );
      _eventLogger.log(
        decision == AdditionalWorkStatus.approved
            ? CustomerOperationEvent.additionalWorkApproved
            : CustomerOperationEvent.additionalWorkDeclined,
        attributes: {'jobId': request.id, 'requestId': additionalWork.id},
      );
      await _refreshMarketplace(request);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      await _refreshMarketplace(request);
    }
  }

  Future<void> createCase({
    required String caseType,
    required String category,
    required String description,
  }) async {
    final request = state.activeRequest;
    if (request == null) return;
    try {
      await _repository.createCase(
        customerTaskId: request.id,
        caseType: caseType,
        category: category,
        description: description,
        idempotencyKey: const Uuid().v4(),
      );
      _eventLogger.log(
        CustomerOperationEvent.disputeCreated,
        attributes: {'jobId': request.id, 'caseType': caseType},
      );
      await _refreshMarketplace(request);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<void> startPayment() async {
    final request = state.activeRequest;
    if (request == null) return;
    try {
      final response = await _repository.createPaymentAttempt(
        customerTaskId: request.id,
        idempotencyKey: const Uuid().v4(),
      );
      if (response['integrationRequired'] == true) {
        state = state.copyWith(
          errorMessage:
              'Online payment is not configured yet. No charge was created.',
        );
      }
      await _refreshMarketplace(request);
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  Future<void> submitRating({
    required int quality,
    required int professionalism,
    required int punctuality,
    required int communication,
    String? comment,
  }) async {
    final request = state.activeRequest;
    if (request == null) return;
    try {
      await _repository.submitRating(
        customerTaskId: request.id,
        quality: quality,
        professionalism: professionalism,
        punctuality: punctuality,
        communication: communication,
        comment: comment,
        idempotencyKey: const Uuid().v4(),
      );
      _eventLogger.log(
        CustomerOperationEvent.ratingSubmitted,
        attributes: {'jobId': request.id},
      );
      state = state.copyWith(clearActive: true, clearError: true);
      unawaited(_marketplaceSubscription?.cancel());
      _marketplaceSubscription = null;
      _marketplaceJobId = null;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
    }
  }

  void retryActiveSearch() {
    final request = state.activeRequest;
    if (request == null) return;

    submitTask(
      category: request.category,
      title: request.title,
      description: request.description,
      location: request.location,
      latitude: request.latitude,
      longitude: request.longitude,
      urgency: request.urgency,
      scheduledAt: request.scheduledAt,
      budget: request.budget,
      workerType: switch (request.serviceType) {
        'helper' => WorkerType.helper,
        'professional' => WorkerType.professional,
        _ => null,
      },
      helperCategory: request.helperCategory,
      professionalCategory: request.professionalCategory,
      estimatedMinPrice: request.estimatedMinPrice,
      estimatedMaxPrice: request.estimatedMaxPrice,
      expectedDuration: request.expectedDuration,
      estimatedDurationMinutes: request.estimatedDurationMinutes,
      pricingSnapshot: request.pricingSnapshot,
      notes: request.notes,
      workCondition: request.workCondition,
    );
  }

  Future<void> _restoreTasks() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final tasks = await _repository.tasks();
      TaskRequest? active;
      for (final task in tasks) {
        if (task.status != TaskStatus.completed &&
            task.status != TaskStatus.cancelled) {
          active = task;
          break;
        }
      }
      final completed =
          tasks.where((task) => task.status == TaskStatus.completed).toList();
      MarketplaceTransaction? marketplace;
      if (active == null && completed.isNotEmpty) {
        try {
          final candidate = await _repository.marketplaceTransaction(
            completed.first.id,
          );
          if (candidate.payment != null && !candidate.ratingSubmitted) {
            active = completed.first;
            marketplace = candidate;
          }
        } catch (_) {
          // Older completed jobs predate the marketplace transaction engine.
        }
      }
      state = state.copyWith(
        activeRequest: active,
        completedRequests: completed,
        isLoading: false,
        marketplaceTransaction: marketplace,
        lifecycleStatus: marketplace == null
            ? active == null
                ? null
                : _lifecycleFromTaskStatus(active.status)
            : _marketplaceLifecycle(marketplace),
      );
      if (active != null) _watchDispatch(active);
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
    }
  }

  void _watchDispatch(TaskRequest request) {
    var requestInFlight = false;
    var consecutiveFailures = 0;
    var acceptanceRecorded = request.selectedOffer != null;
    var dispatchRecoveryAttempted = false;
    late final Timer timer;

    Future<void> check() async {
      if (requestInFlight) return;
      final active = state.activeRequest;
      if (active == null || active.id != request.id) {
        timer.cancel();
        return;
      }
      requestInFlight = true;
      try {
        final dispatch = await _repository.dispatchStatus(request.id);
        consecutiveFailures = 0;
        final previousLifecycle = state.lifecycleStatus;
        state = state.copyWith(
          lifecycleStatus: dispatch.lifecycleStatus,
          dispatchId: dispatch.jobId,
          timeline: dispatch.timeline,
          statusStartedAt: _statusStartedAt(dispatch),
        );
        if (previousLifecycle != dispatch.lifecycleStatus) {
          _logLifecycleTransition(request.id, dispatch.lifecycleStatus);
        }
        if (const {
          'started',
          'completion_requested',
          'completed',
        }.contains(dispatch.status)) {
          _startMarketplaceStream(request);
        }
        if (dispatch.status == 'completed') {
          timer.cancel();
          final current = state.activeRequest;
          if (current == null || current.id != request.id) return;
          try {
            await _repository.updateTaskStatus(current, TaskStatus.completed);
          } catch (_) {
            // The dispatch is authoritative. Keep the customer UI consistent
            // even if an older task service cannot be updated immediately.
          }
          _recordCompleted(current);
        } else if (const {
              'accepted',
              'arrived',
              'started',
              'completion_requested',
            }.contains(dispatch.status) &&
            dispatch.worker != null) {
          final worker = dispatch.worker!;
          final offer = WorkerOffer(
            worker: worker,
            quote: request.budget,
            message: '${worker.name} accepted your request.',
            receivedSecondsAgo: 0,
          );
          final current = state.activeRequest;
          if (current == null || current.id != request.id) return;
          state = state.copyWith(
            activeRequest: current.copyWith(
              status: dispatch.status == 'accepted'
                  ? TaskStatus.workerSelected
                  : TaskStatus.enRoute,
              selectedOffer: offer,
            ),
            offers: [offer],
            completionConfirmationPending:
                dispatch.status == 'completion_requested',
            events: acceptanceRecorded
                ? state.events
                : [
                    BookingEvent(
                      type: BookingEventType.selection,
                      title: '${worker.name} accepted',
                      message: 'Booking confirmed with a verified worker.',
                      timeLabel: 'now',
                    ),
                    ...state.events,
                  ],
          );
          if (!acceptanceRecorded) {
            acceptanceRecorded = true;
            unawaited(_repository
                .updateTaskStatus(
              current,
              TaskStatus.workerSelected,
              workerId: worker.id,
            )
                .catchError((Object error) {
              state = state.copyWith(errorMessage: error.toString());
              return current;
            }));
          }
        } else if (dispatch.status == 'offered' &&
            dispatch.worker == null &&
            (active.selectedOffer != null ||
                active.status == TaskStatus.workerSelected ||
                active.status == TaskStatus.enRoute)) {
          final cancelledWorkerName =
              active.selectedOffer?.worker.name ?? 'The assigned worker';
          acceptanceRecorded = false;
          state = state.copyWith(
            activeRequest: active.copyWith(
              status: TaskStatus.collectingOffers,
              clearSelectedOffer: true,
            ),
            offers: const [],
            completionConfirmationPending: false,
            events: [
              BookingEvent(
                type: BookingEventType.workerResponse,
                title: '$cancelledWorkerName cancelled',
                message:
                    'We are automatically searching for another available worker for up to 2 minutes.',
                timeLabel: 'now',
              ),
              ...state.events,
            ],
          );
          unawaited(_repository
              .updateTaskStatus(active, TaskStatus.collectingOffers)
              .catchError((Object error) {
            state = state.copyWith(errorMessage: error.toString());
            return active;
          }));
        } else if (dispatch.status == 'expired') {
          timer.cancel();
          _cancelTimers();
          final current = state.activeRequest;
          if (current == null || current.id != request.id) return;
          final replacementSearchEnded = current.selectedOffer != null;
          state = state.copyWith(
            activeRequest: current.copyWith(
              status: TaskStatus.noWorkersFound,
              clearSelectedOffer: true,
            ),
            offers: const [],
            completionConfirmationPending: false,
            events: [
              BookingEvent(
                type: BookingEventType.workerResponse,
                title: replacementSearchEnded
                    ? 'No replacement worker found'
                    : 'No worker accepted',
                message: replacementSearchEnded
                    ? 'The automatic replacement attempts have ended. You can retry the search.'
                    : 'The job offer expired without an acceptance.',
                timeLabel: 'now',
              ),
              ...state.events,
            ],
          );
          unawaited(_repository
              .updateTaskStatus(current, TaskStatus.noWorkersFound)
              .catchError((Object error) {
            state = state.copyWith(errorMessage: error.toString());
            return current;
          }));
        } else if (dispatch.offerCount > 0 &&
            active.status == TaskStatus.broadcasting) {
          state = state.copyWith(
            activeRequest: active.copyWith(status: TaskStatus.collectingOffers),
          );
        }
      } catch (error) {
        Object failure = error;
        if (error is CustomerApiException &&
            error.statusCode == 404 &&
            !dispatchRecoveryAttempted &&
            active.status == TaskStatus.broadcasting) {
          dispatchRecoveryAttempted = true;
          try {
            await _repository.ensureDispatch(active);
            consecutiveFailures = 0;
            state = state.copyWith(clearError: true);
            return;
          } catch (recoveryError) {
            failure = recoveryError;
          }
        }
        consecutiveFailures += 1;
        if (consecutiveFailures >= 3) {
          state = state.copyWith(
            errorMessage: 'Unable to refresh worker acceptance: $failure',
          );
        }
      } finally {
        requestInFlight = false;
      }
    }

    timer =
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(check()));
    _timers.add(timer);
    unawaited(check());
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  DateTime? _statusStartedAt(CustomerDispatchStatus dispatch) =>
      switch (dispatch.lifecycleStatus) {
        JobStatus.searching => dispatch.createdAt,
        JobStatus.workerAccepted => dispatch.acceptedAt,
        JobStatus.arrived => dispatch.arrivedAt,
        JobStatus.working => dispatch.startedAt,
        JobStatus.completionRequested => dispatch.completionRequestedAt,
        JobStatus.completed => dispatch.completedAt,
        _ => dispatch.createdAt,
      };

  Future<void> _refreshMarketplace(TaskRequest request) async {
    try {
      final transaction = await _repository.marketplaceTransaction(request.id);
      if (state.activeRequest?.id != request.id) return;
      state = state.copyWith(
        marketplaceTransaction: transaction,
        lifecycleStatus: _marketplaceLifecycle(transaction),
      );
    } on CustomerApiException catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  void _startMarketplaceStream(TaskRequest request) {
    if (_marketplaceJobId == request.id && _marketplaceSubscription != null) {
      return;
    }
    unawaited(_marketplaceSubscription?.cancel());
    _marketplaceJobId = request.id;
    _marketplaceSubscription = _jobEventStream.watch(request.id).listen(
      (transaction) {
        if (state.activeRequest?.id != request.id) return;
        state = state.copyWith(
          marketplaceTransaction: transaction,
          lifecycleStatus: _marketplaceLifecycle(transaction),
          clearError: true,
        );
      },
      onError: (Object error) {
        if (state.activeRequest?.id == request.id) {
          state = state.copyWith(
            errorMessage: 'Unable to refresh job transaction: $error',
          );
        }
      },
    );
  }

  JobStatus _marketplaceLifecycle(MarketplaceTransaction transaction) {
    if (transaction.safetyEvents.isNotEmpty) return JobStatus.safetyIssue;
    if (transaction.disputes.isNotEmpty) return JobStatus.disputed;
    final activeSegment = transaction.activeSegment;
    if (activeSegment != null) {
      return switch (activeSegment.type) {
        TimeSegmentType.working => JobStatus.working,
        TimeSegmentType.customerWaiting ||
        TimeSegmentType.materialWait ||
        TimeSegmentType.specialToolWait =>
          JobStatus.customerWaiting,
        TimeSegmentType.workerBreak => JobStatus.workerBreak,
        TimeSegmentType.workerDelay => JobStatus.workerDelay,
        TimeSegmentType.systemPause => JobStatus.paused,
      };
    }
    if (transaction.pendingAdditionalWork.isNotEmpty) {
      return JobStatus.additionalWorkRequested;
    }
    final payment = transaction.payment;
    if (payment != null) {
      return switch (payment.status) {
        MarketplacePaymentStatus.failed => JobStatus.paymentFailed,
        MarketplacePaymentStatus.success ||
        MarketplacePaymentStatus.notRequired =>
          transaction.ratingSubmitted
              ? JobStatus.closed
              : JobStatus.ratingPending,
        _ => JobStatus.paymentPending,
      };
    }
    return switch (transaction.status) {
      'completion_requested' => JobStatus.completionRequested,
      'completed' => JobStatus.paymentPending,
      _ => JobStatus.working,
    };
  }

  void _logLifecycleTransition(String jobId, JobStatus status) {
    final event = switch (status) {
      JobStatus.workerAssigned => CustomerOperationEvent.workerAssigned,
      JobStatus.workerAccepted => CustomerOperationEvent.workerAccepted,
      JobStatus.workerTravelling => CustomerOperationEvent.workerTravelling,
      JobStatus.arrived => CustomerOperationEvent.workerArrived,
      JobStatus.working => CustomerOperationEvent.jobStarted,
      JobStatus.paused => CustomerOperationEvent.jobPaused,
      JobStatus.completionRequested =>
        CustomerOperationEvent.completionRequested,
      JobStatus.completed => CustomerOperationEvent.jobCompleted,
      JobStatus.cancelled ||
      JobStatus.workerCancelled ||
      JobStatus.customerCancelled =>
        CustomerOperationEvent.jobCancelled,
      _ => null,
    };
    if (event != null) {
      _eventLogger.log(event, attributes: {'jobId': jobId});
    }
  }

  JobStatus _lifecycleFromTaskStatus(TaskStatus status) => switch (status) {
        TaskStatus.draft => JobStatus.requested,
        TaskStatus.broadcasting ||
        TaskStatus.collectingOffers =>
          JobStatus.searching,
        TaskStatus.noWorkersFound => JobStatus.noWorkerAvailable,
        TaskStatus.workerSelected => JobStatus.workerAssigned,
        TaskStatus.enRoute => JobStatus.workerTravelling,
        TaskStatus.completed => JobStatus.completed,
        TaskStatus.cancelled => JobStatus.cancelled,
      };

  @override
  void dispose() {
    _cancelTimers();
    unawaited(_marketplaceSubscription?.cancel());
    super.dispose();
  }
}
