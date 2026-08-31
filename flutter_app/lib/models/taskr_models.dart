import 'package:flutter/material.dart';

import '../domain/job_lifecycle.dart';
import '../domain/marketplace_transaction.dart';

enum TaskUrgency { now, today, scheduled }

enum TaskStatus {
  draft,
  broadcasting,
  collectingOffers,
  noWorkersFound,
  workerSelected,
  enRoute,
  completed,
  cancelled,
}

enum BookingEventType {
  broadcast,
  workerResponse,
  selection,
  arrival,
  completion
}

enum WorkerType { helper, professional }

class ServiceCategory {
  const ServiceCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.averageRate,
    required this.description,
    required this.color,
  });

  final String id;
  final String name;
  final IconData icon;
  final int averageRate;
  final String description;
  final Color color;
}

class WorkerProfile {
  const WorkerProfile({
    required this.id,
    required this.name,
    required this.skill,
    required this.rating,
    required this.jobsCompleted,
    required this.distanceKm,
    required this.etaMinutes,
    required this.hourlyRate,
    required this.verified,
    required this.initials,
    this.workerType = WorkerType.professional,
    this.availability = true,
    this.latitude = 28.6274,
    this.longitude = 77.3723,
    this.locationVerified = false,
  });

  final String id;
  final String name;
  final String skill;
  final double rating;
  final int jobsCompleted;
  final double distanceKm;
  final int etaMinutes;
  final int hourlyRate;
  final bool verified;
  final String initials;
  final WorkerType workerType;
  final bool availability;
  final double latitude;
  final double longitude;
  final bool locationVerified;

  factory WorkerProfile.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? 'Worker';
    final words = name.trim().split(RegExp(r'\s+'));
    final initials = words
        .take(2)
        .where((word) => word.isNotEmpty)
        .map((word) => word[0])
        .join();
    return WorkerProfile(
      id: json['id'] as String,
      name: name,
      skill: json['skill'] as String? ?? 'General helper',
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      jobsCompleted: (json['jobsCompleted'] as num?)?.toInt() ?? 0,
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0,
      etaMinutes: (json['etaMinutes'] as num?)?.toInt() ?? 0,
      hourlyRate: (json['hourlyRate'] as num?)?.toInt() ?? 0,
      verified: json['verified'] == true,
      initials: initials.isEmpty ? 'W' : initials.toUpperCase(),
      workerType: json['workerType'] == 'helper'
          ? WorkerType.helper
          : WorkerType.professional,
      availability: json['availability'] == true,
      latitude: (json['latitude'] as num?)?.toDouble() ?? 28.6274,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 77.3723,
      locationVerified: json['locationVerified'] == true,
    );
  }
}

class WorkerOffer {
  const WorkerOffer({
    required this.worker,
    required this.quote,
    required this.message,
    required this.receivedSecondsAgo,
  });

  final WorkerProfile worker;
  final int quote;
  final String message;
  final int receivedSecondsAgo;
}

class TaskRequest {
  const TaskRequest({
    required this.id,
    required this.category,
    required this.title,
    required this.description,
    required this.location,
    required this.urgency,
    required this.budget,
    required this.status,
    this.selectedOffer,
    this.serviceType,
    this.helperCategory,
    this.professionalCategory,
    this.serviceId,
    this.capabilityKey,
    this.eligibleWorkerCategories = const [],
    this.estimatedMinPrice,
    this.estimatedMaxPrice,
    this.expectedDuration,
    this.estimatedDurationMinutes,
    this.pricingSnapshot,
    this.notes,
    this.workCondition,
    this.createdAt,
    this.scheduledAt,
    this.latitude = 28.6274,
    this.longitude = 77.3723,
  });

  final String id;
  final ServiceCategory category;
  final String title;
  final String description;
  final String location;
  final TaskUrgency urgency;
  final int budget;
  final TaskStatus status;
  final WorkerOffer? selectedOffer;
  final String? serviceType;
  final String? helperCategory;
  final String? professionalCategory;
  final String? serviceId;
  final String? capabilityKey;
  final List<String> eligibleWorkerCategories;
  final int? estimatedMinPrice;
  final int? estimatedMaxPrice;
  final String? expectedDuration;
  final int? estimatedDurationMinutes;
  final Map<String, Object>? pricingSnapshot;
  final String? notes;
  final String? workCondition;
  final DateTime? createdAt;
  final DateTime? scheduledAt;
  final double latitude;
  final double longitude;

  String get budgetLabel => 'Rs $budget';

  TaskRequest copyWith({
    TaskStatus? status,
    WorkerOffer? selectedOffer,
    bool clearSelectedOffer = false,
    String? serviceType,
    String? helperCategory,
    String? professionalCategory,
    String? serviceId,
    String? capabilityKey,
    List<String>? eligibleWorkerCategories,
    int? estimatedMinPrice,
    int? estimatedMaxPrice,
    String? expectedDuration,
    int? estimatedDurationMinutes,
    Map<String, Object>? pricingSnapshot,
    String? notes,
    String? workCondition,
    DateTime? createdAt,
    DateTime? scheduledAt,
  }) {
    return TaskRequest(
      id: id,
      category: category,
      title: title,
      description: description,
      location: location,
      urgency: urgency,
      budget: budget,
      status: status ?? this.status,
      selectedOffer:
          clearSelectedOffer ? null : selectedOffer ?? this.selectedOffer,
      serviceType: serviceType ?? this.serviceType,
      helperCategory: helperCategory ?? this.helperCategory,
      professionalCategory: professionalCategory ?? this.professionalCategory,
      serviceId: serviceId ?? this.serviceId,
      capabilityKey: capabilityKey ?? this.capabilityKey,
      eligibleWorkerCategories:
          eligibleWorkerCategories ?? this.eligibleWorkerCategories,
      estimatedMinPrice: estimatedMinPrice ?? this.estimatedMinPrice,
      estimatedMaxPrice: estimatedMaxPrice ?? this.estimatedMaxPrice,
      expectedDuration: expectedDuration ?? this.expectedDuration,
      estimatedDurationMinutes:
          estimatedDurationMinutes ?? this.estimatedDurationMinutes,
      pricingSnapshot: pricingSnapshot ?? this.pricingSnapshot,
      notes: notes ?? this.notes,
      workCondition: workCondition ?? this.workCondition,
      createdAt: createdAt ?? this.createdAt,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      latitude: latitude,
      longitude: longitude,
    );
  }

  factory TaskRequest.fromJson(
    Map<String, dynamic> json, {
    required Map<String, ServiceCategory> categories,
  }) {
    final categoryId = json['category'] as String? ?? 'labour';
    return TaskRequest(
      id: json['id'] as String,
      category: categories[categoryId] ?? categories.values.first,
      title: json['title'] as String? ?? categoryId,
      description: json['description'] as String? ?? '',
      location: json['location'] as String? ?? 'Current location',
      urgency: TaskUrgency.values.firstWhere(
        (value) => value.name == json['urgency'],
        orElse: () => TaskUrgency.now,
      ),
      budget: (json['budget'] as num?)?.toInt() ?? 0,
      status: TaskStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => TaskStatus.broadcasting,
      ),
      serviceType: json['serviceType'] as String?,
      helperCategory: json['helperCategory'] as String?,
      professionalCategory: json['professionalCategory'] as String?,
      serviceId: json['serviceId'] as String?,
      capabilityKey: json['capabilityKey'] as String?,
      eligibleWorkerCategories:
          (json['eligibleWorkerCategories'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      estimatedMinPrice: (json['estimatedMinPrice'] as num?)?.toInt(),
      estimatedMaxPrice: (json['estimatedMaxPrice'] as num?)?.toInt(),
      expectedDuration: json['expectedDuration'] as String?,
      estimatedDurationMinutes:
          (json['estimatedDurationMinutes'] as num?)?.toInt(),
      pricingSnapshot: switch (json['pricingSnapshot']) {
        Map<String, dynamic> value => value.map(
            (key, value) => MapEntry(key, value as Object),
          ),
        _ => null,
      },
      notes: json['notes'] as String?,
      workCondition: json['workCondition'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      scheduledAt:
          DateTime.tryParse(json['scheduledAt'] as String? ?? '')?.toLocal(),
      latitude: (json['latitude'] as num?)?.toDouble() ?? 28.6274,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 77.3723,
    );
  }
}

class BookingEvent {
  const BookingEvent({
    required this.type,
    required this.title,
    required this.message,
    required this.timeLabel,
  });

  final BookingEventType type;
  final String title;
  final String message;
  final String timeLabel;
}

class BookingState {
  const BookingState({
    this.activeRequest,
    this.offers = const [],
    this.events = const [],
    this.completedRequests = const [],
    this.isLoading = false,
    this.completionConfirmationPending = false,
    this.lifecycleStatus,
    this.dispatchId,
    this.timeline = const [],
    this.statusStartedAt,
    this.marketplaceTransaction,
    this.errorMessage,
  });

  final TaskRequest? activeRequest;
  final List<WorkerOffer> offers;
  final List<BookingEvent> events;
  final List<TaskRequest> completedRequests;
  final bool isLoading;
  final bool completionConfirmationPending;
  final JobStatus? lifecycleStatus;
  final String? dispatchId;
  final List<JobTimelineEvent> timeline;
  final DateTime? statusStartedAt;
  final MarketplaceTransaction? marketplaceTransaction;
  final String? errorMessage;

  bool get isCreatingRequest => isLoading && activeRequest == null;

  BookingState copyWith({
    TaskRequest? activeRequest,
    List<WorkerOffer>? offers,
    List<BookingEvent>? events,
    List<TaskRequest>? completedRequests,
    bool clearActive = false,
    bool? isLoading,
    bool? completionConfirmationPending,
    JobStatus? lifecycleStatus,
    String? dispatchId,
    List<JobTimelineEvent>? timeline,
    DateTime? statusStartedAt,
    MarketplaceTransaction? marketplaceTransaction,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BookingState(
      activeRequest: clearActive ? null : activeRequest ?? this.activeRequest,
      offers: offers ?? this.offers,
      events: events ?? this.events,
      completedRequests: completedRequests ?? this.completedRequests,
      isLoading: isLoading ?? this.isLoading,
      completionConfirmationPending:
          completionConfirmationPending ?? this.completionConfirmationPending,
      lifecycleStatus:
          clearActive ? null : lifecycleStatus ?? this.lifecycleStatus,
      dispatchId: clearActive ? null : dispatchId ?? this.dispatchId,
      timeline: clearActive ? const [] : timeline ?? this.timeline,
      statusStartedAt:
          clearActive ? null : statusStartedAt ?? this.statusStartedAt,
      marketplaceTransaction: clearActive
          ? null
          : marketplaceTransaction ?? this.marketplaceTransaction,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}
