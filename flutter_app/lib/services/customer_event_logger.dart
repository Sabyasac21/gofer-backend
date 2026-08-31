import 'dart:convert';

import 'package:flutter/foundation.dart';

enum CustomerOperationEvent {
  bookingStarted,
  serviceSelected,
  bookingCreated,
  matchingStarted,
  workerAssigned,
  workerAccepted,
  workerTravelling,
  workerMatched,
  workerArrived,
  jobStarted,
  jobPaused,
  customerWaitingStarted,
  customerWaitingEnded,
  materialRequested,
  specialToolRequired,
  additionalWorkRequested,
  additionalWorkApproved,
  additionalWorkDeclined,
  completionRequested,
  completionConfirmed,
  jobCompleted,
  disputeCreated,
  paymentStarted,
  paymentCompleted,
  paymentFailed,
  ratingSubmitted,
  jobCancelled,
  jobClosed,
}

extension CustomerOperationEventName on CustomerOperationEvent {
  String get wireName => switch (this) {
        CustomerOperationEvent.bookingStarted => 'booking_started',
        CustomerOperationEvent.serviceSelected => 'service_selected',
        CustomerOperationEvent.bookingCreated => 'booking_created',
        CustomerOperationEvent.matchingStarted => 'worker_search_started',
        CustomerOperationEvent.workerAssigned => 'worker_assigned',
        CustomerOperationEvent.workerAccepted => 'worker_accepted',
        CustomerOperationEvent.workerTravelling => 'worker_travelling',
        CustomerOperationEvent.workerMatched => 'worker_matched',
        CustomerOperationEvent.workerArrived => 'worker_arrived',
        CustomerOperationEvent.jobStarted => 'job_started',
        CustomerOperationEvent.jobPaused => 'job_paused',
        CustomerOperationEvent.customerWaitingStarted =>
          'customer_waiting_started',
        CustomerOperationEvent.customerWaitingEnded => 'customer_waiting_ended',
        CustomerOperationEvent.materialRequested => 'material_required',
        CustomerOperationEvent.specialToolRequired => 'special_tool_required',
        CustomerOperationEvent.additionalWorkRequested =>
          'additional_work_requested',
        CustomerOperationEvent.additionalWorkApproved =>
          'additional_work_approved',
        CustomerOperationEvent.additionalWorkDeclined =>
          'additional_work_declined',
        CustomerOperationEvent.completionRequested => 'completion_requested',
        CustomerOperationEvent.completionConfirmed => 'completion_confirmed',
        CustomerOperationEvent.jobCompleted => 'job_completed',
        CustomerOperationEvent.disputeCreated => 'dispute_created',
        CustomerOperationEvent.paymentStarted => 'payment_started',
        CustomerOperationEvent.paymentCompleted => 'payment_completed',
        CustomerOperationEvent.paymentFailed => 'payment_failed',
        CustomerOperationEvent.ratingSubmitted => 'rating_submitted',
        CustomerOperationEvent.jobCancelled => 'job_cancelled',
        CustomerOperationEvent.jobClosed => 'job_closed',
      };
}

abstract interface class CustomerEventLogger {
  void log(CustomerOperationEvent event, {Map<String, Object?> attributes});
}

class StructuredCustomerEventLogger implements CustomerEventLogger {
  const StructuredCustomerEventLogger();

  static const _blockedKeyFragments = {
    'phone',
    'address',
    'token',
    'payment',
    'description',
  };

  @override
  void log(
    CustomerOperationEvent event, {
    Map<String, Object?> attributes = const {},
  }) {
    final safeAttributes = Map<String, Object?>.fromEntries(
      attributes.entries.where(
        (entry) => !_blockedKeyFragments.any(
          (fragment) => entry.key.toLowerCase().contains(fragment),
        ),
      ),
    );
    debugPrint(
      jsonEncode({
        'event': event.wireName,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'attributes': safeAttributes,
      }),
    );
  }
}
