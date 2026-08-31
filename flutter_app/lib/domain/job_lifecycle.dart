enum JobStatus {
  requested,
  searching,
  workerAssigned,
  workerAccepted,
  workerTravelling,
  arrived,
  readyToStart,
  working,
  customerWaiting,
  workerBreak,
  workerDelay,
  paused,
  materialRequired,
  specialToolRequired,
  additionalWorkRequested,
  customerActionRequired,
  completionRequested,
  customerReview,
  completed,
  paymentPending,
  paymentFailed,
  ratingPending,
  disputed,
  safetyIssue,
  customerNoShow,
  noWorkerAvailable,
  workerCancelled,
  customerCancelled,
  cancelled,
  resolving,
  closed,
}

enum JobEventType {
  jobCreated,
  workerAssigned,
  workerAccepted,
  workerStartedTravel,
  workerArrived,
  jobStarted,
  jobPaused,
  customerWaitingStarted,
  customerWaitingEnded,
  materialRequired,
  specialToolRequired,
  additionalWorkRequested,
  additionalWorkApproved,
  additionalWorkDeclined,
  jobCompletionRequested,
  customerCompleted,
  customerDisputed,
  jobCancelled,
  paymentCompleted,
}

enum AdditionalWorkDecision { pending, approved, declined }

enum CustomerPaymentStatus { notStarted, pending, paid, failed, cancelled }

enum WaitingReason {
  customerAction,
  material,
  workerBreak,
  workerDelay,
  paused
}

enum DisputeReason {
  incompleteWork,
  poorQuality,
  wrongService,
  propertyDamage,
  unauthorizedPayment,
  additionalCashRequested,
  improperBehaviour,
  safetyIssue,
  other,
}

class JobScopeItem {
  const JobScopeItem({
    required this.id,
    required this.label,
    this.completed = false,
    this.additional = false,
  });

  final String id;
  final String label;
  final bool completed;
  final bool additional;
}

class JobScope {
  const JobScope({required this.original, this.approvedAdditional = const []});

  final List<JobScopeItem> original;
  final List<JobScopeItem> approvedAdditional;

  List<JobScopeItem> get agreedItems => [...original, ...approvedAdditional];
}

class AdditionalWorkRequest {
  const AdditionalWorkRequest({
    required this.id,
    required this.description,
    required this.additionalLabour,
    required this.additionalMinutes,
    this.decision = AdditionalWorkDecision.pending,
  });

  final String id;
  final String description;
  final int additionalLabour;
  final int additionalMinutes;
  final AdditionalWorkDecision decision;

  AdditionalWorkRequest decide(AdditionalWorkDecision value) =>
      AdditionalWorkRequest(
        id: id,
        description: description,
        additionalLabour: additionalLabour,
        additionalMinutes: additionalMinutes,
        decision: value,
      );
}

class MaterialRequirement {
  const MaterialRequirement({
    required this.id,
    required this.items,
    this.note,
    this.resolved = false,
  });

  final String id;
  final List<String> items;
  final String? note;
  final bool resolved;
}

class WaitingSession {
  const WaitingSession({
    required this.reason,
    required this.startedAt,
    this.endedAt,
    this.compensationMessage,
  });

  final WaitingReason reason;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? compensationMessage;

  Duration durationAt(DateTime now) => (endedAt ?? now).difference(startedAt);
}

class CompletionEvidence {
  const CompletionEvidence({
    required this.id,
    required this.kind,
    required this.uri,
    this.note,
  });

  final String id;
  final String kind;
  final Uri uri;
  final String? note;
}

class JobTimelineEvent {
  const JobTimelineEvent({
    required this.id,
    required this.type,
    required this.status,
    required this.occurredAt,
    required this.title,
    this.details,
  });

  final String id;
  final JobEventType type;
  final JobStatus status;
  final DateTime occurredAt;
  final String title;
  final String? details;
}

class Dispute {
  const Dispute({
    required this.id,
    required this.jobId,
    required this.reason,
    required this.description,
    required this.createdAt,
    this.evidence = const [],
  });

  final String id;
  final String jobId;
  final DisputeReason reason;
  final String description;
  final DateTime createdAt;
  final List<CompletionEvidence> evidence;
}

class LabourPayment {
  const LabourPayment({
    required this.originalLabour,
    this.approvedAdditionalLabour = 0,
    this.backendProvidedWaitingCompensation = 0,
  });

  final int originalLabour;
  final int approvedAdditionalLabour;
  final int backendProvidedWaitingCompensation;

  int get displayedTotal =>
      originalLabour +
      approvedAdditionalLabour +
      backendProvidedWaitingCompensation;
}

class CustomerPayment {
  const CustomerPayment({
    required this.id,
    required this.jobId,
    required this.status,
    required this.labour,
    this.failureMessage,
    this.updatedAt,
  });

  final String id;
  final String jobId;
  final CustomerPaymentStatus status;
  final LabourPayment labour;
  final String? failureMessage;
  final DateTime? updatedAt;
}

class CustomerRating {
  const CustomerRating({
    required this.jobId,
    required this.quality,
    required this.professionalism,
    required this.punctuality,
    required this.communication,
    this.comment,
  });

  final String jobId;
  final int quality;
  final int professionalism;
  final int punctuality;
  final int communication;
  final String? comment;
}

class SafetyIssue {
  const SafetyIssue({
    required this.jobId,
    required this.category,
    required this.description,
    required this.createdAt,
  });

  final String jobId;
  final String category;
  final String description;
  final DateTime createdAt;
}

class JobLifecyclePolicy {
  const JobLifecyclePolicy();

  static const Map<JobStatus, Set<JobStatus>> _allowed = {
    JobStatus.requested: {JobStatus.searching, JobStatus.cancelled},
    JobStatus.searching: {
      JobStatus.workerAssigned,
      JobStatus.noWorkerAvailable,
      JobStatus.cancelled,
      JobStatus.customerCancelled,
    },
    JobStatus.workerAssigned: {
      JobStatus.workerAccepted,
      JobStatus.searching,
      JobStatus.workerCancelled,
      JobStatus.cancelled,
      JobStatus.customerCancelled,
    },
    JobStatus.workerAccepted: {
      JobStatus.workerTravelling,
      JobStatus.searching,
      JobStatus.workerCancelled,
      JobStatus.cancelled,
      JobStatus.customerCancelled,
    },
    JobStatus.workerTravelling: {
      JobStatus.arrived,
      JobStatus.workerDelay,
      JobStatus.searching,
      JobStatus.workerCancelled,
      JobStatus.cancelled,
      JobStatus.customerCancelled,
    },
    JobStatus.arrived: {
      JobStatus.readyToStart,
      JobStatus.customerNoShow,
      JobStatus.cancelled,
      JobStatus.customerCancelled,
    },
    JobStatus.readyToStart: {JobStatus.working, JobStatus.cancelled},
    JobStatus.working: {
      JobStatus.customerWaiting,
      JobStatus.workerBreak,
      JobStatus.workerDelay,
      JobStatus.paused,
      JobStatus.materialRequired,
      JobStatus.specialToolRequired,
      JobStatus.additionalWorkRequested,
      JobStatus.completionRequested,
      JobStatus.disputed,
      JobStatus.safetyIssue,
      JobStatus.cancelled,
    },
    JobStatus.customerWaiting: {JobStatus.working, JobStatus.cancelled},
    JobStatus.workerBreak: {JobStatus.working, JobStatus.cancelled},
    JobStatus.workerDelay: {
      JobStatus.workerTravelling,
      JobStatus.working,
      JobStatus.cancelled,
    },
    JobStatus.paused: {JobStatus.working, JobStatus.cancelled},
    JobStatus.materialRequired: {
      JobStatus.customerWaiting,
      JobStatus.working,
      JobStatus.cancelled,
    },
    JobStatus.specialToolRequired: {
      JobStatus.customerActionRequired,
      JobStatus.working,
      JobStatus.cancelled,
    },
    JobStatus.additionalWorkRequested: {
      JobStatus.working,
      JobStatus.cancelled,
    },
    JobStatus.customerActionRequired: {
      JobStatus.working,
      JobStatus.cancelled,
    },
    JobStatus.completionRequested: {
      JobStatus.customerReview,
      JobStatus.working,
      JobStatus.disputed,
    },
    JobStatus.customerReview: {
      JobStatus.completed,
      JobStatus.working,
      JobStatus.disputed,
    },
    JobStatus.completed: {
      JobStatus.paymentPending,
      JobStatus.ratingPending,
      JobStatus.closed,
      JobStatus.disputed,
    },
    JobStatus.paymentPending: {
      JobStatus.paymentFailed,
      JobStatus.ratingPending,
      JobStatus.disputed,
    },
    JobStatus.paymentFailed: {
      JobStatus.paymentPending,
      JobStatus.disputed,
    },
    JobStatus.ratingPending: {JobStatus.closed},
    JobStatus.disputed: {JobStatus.resolving},
    JobStatus.safetyIssue: {JobStatus.resolving, JobStatus.cancelled},
    JobStatus.customerNoShow: {
      JobStatus.readyToStart,
      JobStatus.resolving,
      JobStatus.cancelled,
    },
    JobStatus.noWorkerAvailable: {
      JobStatus.searching,
      JobStatus.customerCancelled,
    },
    JobStatus.workerCancelled: {
      JobStatus.searching,
      JobStatus.cancelled,
    },
    JobStatus.customerCancelled: {JobStatus.closed},
    JobStatus.resolving: {JobStatus.completed, JobStatus.cancelled},
    JobStatus.cancelled: {JobStatus.closed},
    JobStatus.closed: {},
  };

  bool canTransition(JobStatus from, JobStatus to) =>
      _allowed[from]?.contains(to) ?? false;
}
