enum WorkerReviewStatus {
  notStarted,
  draft,
  submitted,
  underReview,
  needsCorrection,
  approved,
  rejected,
}

enum WorkerDocumentType { nationalIdFront, nationalIdBack, selfie }

enum WorkerJobStatus {
  offered,
  accepted,
  arrived,
  started,
  completionRequested,
  completed,
}

enum WorkerEnrollmentType { helper, professional }

enum IndianIdType {
  aadhaar,
  drivingLicence,
  voterId,
  pan,
  passport,
}

extension IndianIdTypeLabel on IndianIdType {
  String get label {
    return switch (this) {
      IndianIdType.aadhaar => 'Aadhaar Card',
      IndianIdType.drivingLicence => 'Driving Licence',
      IndianIdType.voterId => 'Voter ID',
      IndianIdType.pan => 'PAN Card',
      IndianIdType.passport => 'Passport',
    };
  }
}

class WorkerDocument {
  const WorkerDocument({
    required this.type,
    required this.path,
    this.fileName = '',
    this.contentType = 'image/jpeg',
    this.contentBase64 = '',
    this.validationChecks = const <DocumentValidationCheck>[],
    this.extractedFields = const <String, String>{},
  });

  final WorkerDocumentType type;
  final String path;
  final String fileName;
  final String contentType;
  final String contentBase64;
  final List<DocumentValidationCheck> validationChecks;
  final Map<String, String> extractedFields;
}

class DocumentValidationCheck {
  const DocumentValidationCheck({
    required this.label,
    required this.passed,
    required this.message,
  });

  final String label;
  final bool passed;
  final String message;
}

class WorkerApplication {
  const WorkerApplication({
    this.phone = '',
    this.language = 'English',
    this.fullName = '',
    this.age = '',
    this.city = '',
    this.workArea = '',
    this.emergencyContact = '',
    this.experience = 'Beginner',
    this.travelRadiusKm = 3,
    this.enrollmentTypes = const <WorkerEnrollmentType>{},
    this.professionalCategories = const <String>{},
    this.idType,
    this.documents = const <WorkerDocumentType, WorkerDocument>{},
    this.consentAccepted = false,
    this.consentVersion = 'worker-verification-v1',
    this.consentAcceptedAt,
    this.status = WorkerReviewStatus.notStarted,
  });

  final String phone;
  final String language;
  final String fullName;
  final String age;
  final String city;
  final String workArea;
  final String emergencyContact;
  final String experience;
  final int travelRadiusKm;
  final Set<WorkerEnrollmentType> enrollmentTypes;
  final Set<String> professionalCategories;
  final IndianIdType? idType;
  final Map<WorkerDocumentType, WorkerDocument> documents;
  final bool consentAccepted;
  final String consentVersion;
  final DateTime? consentAcceptedAt;
  final WorkerReviewStatus status;

  bool get enrolledAsHelper =>
      enrollmentTypes.contains(WorkerEnrollmentType.helper);

  bool get enrolledAsProfessional =>
      enrollmentTypes.contains(WorkerEnrollmentType.professional);

  bool get hasRequiredWorkSelection =>
      enrolledAsHelper ||
      (enrolledAsProfessional && professionalCategories.isNotEmpty);

  bool get hasRequiredProfile =>
      fullName.trim().isNotEmpty &&
      age.trim().isNotEmpty &&
      city.trim().isNotEmpty &&
      workArea.trim().isNotEmpty;

  bool get hasRequiredDocuments =>
      idType != null &&
      documents.containsKey(WorkerDocumentType.nationalIdFront) &&
      documents.containsKey(WorkerDocumentType.nationalIdBack) &&
      documents.containsKey(WorkerDocumentType.selfie);

  bool get canSubmit =>
      hasRequiredProfile &&
      hasRequiredWorkSelection &&
      hasRequiredDocuments &&
      consentAccepted;

  WorkerApplication copyWith({
    String? phone,
    String? language,
    String? fullName,
    String? age,
    String? city,
    String? workArea,
    String? emergencyContact,
    String? experience,
    int? travelRadiusKm,
    Set<WorkerEnrollmentType>? enrollmentTypes,
    Set<String>? professionalCategories,
    IndianIdType? idType,
    Map<WorkerDocumentType, WorkerDocument>? documents,
    bool? consentAccepted,
    String? consentVersion,
    DateTime? consentAcceptedAt,
    bool clearConsentAcceptedAt = false,
    WorkerReviewStatus? status,
  }) {
    return WorkerApplication(
      phone: phone ?? this.phone,
      language: language ?? this.language,
      fullName: fullName ?? this.fullName,
      age: age ?? this.age,
      city: city ?? this.city,
      workArea: workArea ?? this.workArea,
      emergencyContact: emergencyContact ?? this.emergencyContact,
      experience: experience ?? this.experience,
      travelRadiusKm: travelRadiusKm ?? this.travelRadiusKm,
      enrollmentTypes: enrollmentTypes ?? this.enrollmentTypes,
      professionalCategories:
          professionalCategories ?? this.professionalCategories,
      idType: idType ?? this.idType,
      documents: documents ?? this.documents,
      consentAccepted: consentAccepted ?? this.consentAccepted,
      consentVersion: consentVersion ?? this.consentVersion,
      consentAcceptedAt: clearConsentAcceptedAt
          ? null
          : consentAcceptedAt ?? this.consentAcceptedAt,
      status: status ?? this.status,
    );
  }
}

class WorkerJobRequest {
  const WorkerJobRequest({
    required this.id,
    required this.workType,
    required this.customerArea,
    required this.distanceKm,
    required this.durationLabel,
    required this.payMin,
    required this.payMax,
    required this.notes,
    required this.status,
    this.expiresAt,
  });

  final String id;
  final String workType;
  final String customerArea;
  final double distanceKm;
  final String durationLabel;
  final int payMin;
  final int payMax;
  final String notes;
  final WorkerJobStatus status;
  final DateTime? expiresAt;

  String get payLabel => 'Rs $payMin - Rs $payMax';
  bool get isExpired =>
      status == WorkerJobStatus.offered &&
      expiresAt != null &&
      !expiresAt!.isAfter(DateTime.now().toUtc());

  factory WorkerJobRequest.fromJson(Map<String, dynamic> json) {
    int parseAmount(Object? value) => switch (value) {
          num amount => amount.toInt(),
          String amount => int.tryParse(amount) ?? 0,
          _ => 0,
        };
    double parseDistance(Object? value) => switch (value) {
          num distance => distance.toDouble(),
          String distance => double.tryParse(distance) ?? 0,
          _ => 0,
        };

    return WorkerJobRequest(
      id: json['id'] as String? ?? json['jobId'] as String? ?? '',
      workType: json['workType'] as String? ?? 'New job',
      customerArea: json['customerArea'] as String? ?? 'Customer location',
      distanceKm: parseDistance(json['distanceKm']),
      durationLabel: json['durationLabel'] as String? ?? 'New request',
      payMin: parseAmount(json['payMin'] ?? json['budget']),
      payMax: parseAmount(json['payMax'] ?? json['budget']),
      notes: json['notes'] as String? ?? '',
      status: WorkerJobStatus.values.firstWhere(
        (status) =>
            status.name == json['status'] ||
            (status == WorkerJobStatus.completionRequested &&
                json['status'] == 'completion_requested'),
        orElse: () => WorkerJobStatus.offered,
      ),
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'workType': workType,
        'customerArea': customerArea,
        'distanceKm': distanceKm,
        'durationLabel': durationLabel,
        'payMin': payMin,
        'payMax': payMax,
        'notes': notes,
        'status': status.name,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  WorkerJobRequest copyWith({
    WorkerJobStatus? status,
    DateTime? expiresAt,
  }) {
    return WorkerJobRequest(
      id: id,
      workType: workType,
      customerArea: customerArea,
      distanceKm: distanceKm,
      durationLabel: durationLabel,
      payMin: payMin,
      payMax: payMax,
      notes: notes,
      status: status ?? this.status,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

class WorkerJobHistoryItem {
  const WorkerJobHistoryItem({
    required this.id,
    required this.workType,
    required this.customerArea,
    required this.amount,
    required this.completedAt,
  });

  final String id;
  final String workType;
  final String customerArea;
  final int amount;
  final DateTime completedAt;

  factory WorkerJobHistoryItem.fromJson(Map<String, dynamic> json) {
    final amount = json['budget'];
    return WorkerJobHistoryItem(
      id: json['id'] as String? ?? '',
      workType: json['workType'] as String? ?? 'Completed job',
      customerArea: json['customerArea'] as String? ?? 'Customer location',
      amount: amount is num ? amount.toInt() : int.tryParse('$amount') ?? 0,
      completedAt:
          DateTime.tryParse(json['completedAt'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'workType': workType,
        'customerArea': customerArea,
        'budget': amount,
        'completedAt': completedAt.toUtc().toIso8601String(),
      };
}

class WorkerDashboardSnapshot {
  const WorkerDashboardSnapshot({
    required this.earningsToday,
    required this.totalEarnings,
    required this.completedJobs,
    required this.history,
  });

  final int earningsToday;
  final int totalEarnings;
  final int completedJobs;
  final List<WorkerJobHistoryItem> history;

  factory WorkerDashboardSnapshot.fromJson(Map<String, dynamic> json) {
    int amount(Object? value) =>
        value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    final rawHistory = json['history'];
    return WorkerDashboardSnapshot(
      earningsToday: amount(json['earningsToday']),
      totalEarnings: amount(json['totalEarnings']),
      completedJobs: amount(json['completedJobs']),
      history: rawHistory is List
          ? rawHistory
              .whereType<Map>()
              .map((item) => WorkerJobHistoryItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList(growable: false)
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'earningsToday': earningsToday,
        'totalEarnings': totalEarnings,
        'completedJobs': completedJobs,
        'history': history.map((item) => item.toJson()).toList(),
      };
}

class WorkerState {
  const WorkerState({
    this.phoneVerified = false,
    this.otpSent = false,
    this.pendingPhone = '',
    this.devOtp = '',
    this.otpExpiresAt,
    this.otpAttempts = 0,
    this.onboardingStep = 0,
    this.online = false,
    this.earningsToday = 0,
    this.totalEarnings = 0,
    this.completedJobs = 0,
    this.jobHistory = const [],
    this.application = const WorkerApplication(),
    this.currentJob,
    this.submittingEnrollment = false,
    this.enrollmentError,
    this.checkingEnrollmentStatus = false,
    this.existingEnrollment,
    this.restoringSession = true,
    this.updatingAvailability = false,
    this.availabilityError,
    this.availabilityRequiresSettings = false,
    this.jobActionInProgress = false,
    this.jobActionError,
  });

  final bool phoneVerified;
  final bool otpSent;
  final String pendingPhone;
  final String devOtp;
  final DateTime? otpExpiresAt;
  final int otpAttempts;
  final int onboardingStep;
  final bool online;
  final int earningsToday;
  final int totalEarnings;
  final int completedJobs;
  final List<WorkerJobHistoryItem> jobHistory;
  final WorkerApplication application;
  final WorkerJobRequest? currentJob;
  final bool submittingEnrollment;
  final String? enrollmentError;
  final bool checkingEnrollmentStatus;
  final ExistingWorkerEnrollment? existingEnrollment;
  final bool restoringSession;
  final bool updatingAvailability;
  final String? availabilityError;
  final bool availabilityRequiresSettings;
  final bool jobActionInProgress;
  final String? jobActionError;

  WorkerState copyWith({
    bool? phoneVerified,
    bool? otpSent,
    String? pendingPhone,
    String? devOtp,
    DateTime? otpExpiresAt,
    int? otpAttempts,
    int? onboardingStep,
    bool? online,
    int? earningsToday,
    int? totalEarnings,
    int? completedJobs,
    List<WorkerJobHistoryItem>? jobHistory,
    WorkerApplication? application,
    WorkerJobRequest? currentJob,
    bool clearJob = false,
    bool? submittingEnrollment,
    String? enrollmentError,
    bool clearEnrollmentError = false,
    bool? checkingEnrollmentStatus,
    ExistingWorkerEnrollment? existingEnrollment,
    bool clearExistingEnrollment = false,
    bool? restoringSession,
    bool? updatingAvailability,
    String? availabilityError,
    bool clearAvailabilityError = false,
    bool? availabilityRequiresSettings,
    bool? jobActionInProgress,
    String? jobActionError,
    bool clearJobActionError = false,
  }) {
    return WorkerState(
      phoneVerified: phoneVerified ?? this.phoneVerified,
      otpSent: otpSent ?? this.otpSent,
      pendingPhone: pendingPhone ?? this.pendingPhone,
      devOtp: devOtp ?? this.devOtp,
      otpExpiresAt: otpExpiresAt ?? this.otpExpiresAt,
      otpAttempts: otpAttempts ?? this.otpAttempts,
      onboardingStep: onboardingStep ?? this.onboardingStep,
      online: online ?? this.online,
      earningsToday: earningsToday ?? this.earningsToday,
      totalEarnings: totalEarnings ?? this.totalEarnings,
      completedJobs: completedJobs ?? this.completedJobs,
      jobHistory: jobHistory ?? this.jobHistory,
      application: application ?? this.application,
      currentJob: clearJob ? null : currentJob ?? this.currentJob,
      submittingEnrollment: submittingEnrollment ?? this.submittingEnrollment,
      enrollmentError:
          clearEnrollmentError ? null : enrollmentError ?? this.enrollmentError,
      checkingEnrollmentStatus:
          checkingEnrollmentStatus ?? this.checkingEnrollmentStatus,
      existingEnrollment: clearExistingEnrollment
          ? null
          : existingEnrollment ?? this.existingEnrollment,
      restoringSession: restoringSession ?? this.restoringSession,
      updatingAvailability: updatingAvailability ?? this.updatingAvailability,
      availabilityError: clearAvailabilityError
          ? null
          : availabilityError ?? this.availabilityError,
      availabilityRequiresSettings: clearAvailabilityError
          ? false
          : availabilityRequiresSettings ?? this.availabilityRequiresSettings,
      jobActionInProgress: jobActionInProgress ?? this.jobActionInProgress,
      jobActionError:
          clearJobActionError ? null : jobActionError ?? this.jobActionError,
    );
  }
}

class ExistingWorkerEnrollment {
  const ExistingWorkerEnrollment({
    required this.id,
    required this.fullName,
    required this.reviewStatus,
    required this.workerStatus,
    required this.kycStatus,
    this.submittedAt,
  });

  final String id;
  final String fullName;
  final String reviewStatus;
  final String workerStatus;
  final String kycStatus;
  final DateTime? submittedAt;
}
