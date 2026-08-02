import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/worker_models.dart';
import '../services/worker_enrollment_service.dart';
import '../services/worker_otp_service.dart';
import '../services/worker_session_store.dart';
import '../services/worker_dispatch_service.dart';

final workerControllerProvider =
    StateNotifierProvider<WorkerController, WorkerState>(
  (ref) => WorkerController(
    WorkerEnrollmentService(),
    WorkerSessionStore(),
  ),
);

class WorkerController extends StateNotifier<WorkerState> {
  WorkerController(
    this._enrollmentService,
    this._sessionStore, {
    WorkerOtpService? otpService,
    WorkerDispatchGateway? dispatchService,
    bool restoreSessionOnStart = true,
  })  : _otpService = otpService ?? WorkerOtpService(),
        _dispatchService = dispatchService ?? WorkerDispatchService.instance,
        super(const WorkerState()) {
    _dispatchService.onJob = receiveJob;
    _tokenRefreshSubscription = _dispatchService.tokenRefreshes.listen(
      _handleTokenRefresh,
      onError: (_) {},
    );
    _jobCancellationSubscription = _dispatchService.cancelledJobIds.listen(
      _handleJobCancellation,
      onError: (_) {},
    );
    if (restoreSessionOnStart) restoreSession();
  }

  final WorkerEnrollmentService _enrollmentService;
  final WorkerSessionStore _sessionStore;
  final WorkerOtpService _otpService;
  final WorkerDispatchGateway _dispatchService;
  Timer? _presenceHeartbeat;
  Timer? _jobStatusTimer;
  bool _jobStatusRefreshInFlight = false;
  late final StreamSubscription<String> _tokenRefreshSubscription;
  late final StreamSubscription<String> _jobCancellationSubscription;
  WorkerSettingsTarget? _availabilitySettingsTarget;

  static final RegExp _indianMobilePattern = RegExp(r'^[6-9]\d{9}$');

  String? validatePhone(String phone) {
    final normalized = phone.trim();
    if (normalized.length != 10) {
      return 'Enter a 10 digit mobile number.';
    }
    if (!_indianMobilePattern.hasMatch(normalized)) {
      return 'Enter a valid Indian mobile number starting with 6, 7, 8 or 9.';
    }
    return null;
  }

  Future<String?> requestOtp(String phone) async {
    final validationError = validatePhone(phone);
    if (validationError != null) return validationError;

    state = state.copyWith(
      checkingEnrollmentStatus: true,
      clearEnrollmentError: true,
    );
    try {
      final result = await _otpService.sendOtp(phone.trim());
      state = state.copyWith(
        otpSent: true,
        pendingPhone: phone.trim(),
        devOtp: '',
        otpExpiresAt: DateTime.now().add(Duration(seconds: result.expiresIn)),
        otpAttempts: 0,
        checkingEnrollmentStatus: false,
      );
      return null;
    } catch (error) {
      final message = error is WorkerOtpException
          ? error.message
          : 'Could not send verification code. Please try again.';
      state = state.copyWith(
        otpSent: false,
        pendingPhone: '',
        checkingEnrollmentStatus: false,
        enrollmentError: message,
      );
      return message;
    }
  }

  Future<String?> verifyOtpAndCheckEnrollment(String otp) async {
    if (!state.otpSent || state.pendingPhone.isEmpty) {
      return 'Request a verification code first.';
    }
    if (!RegExp(r'^\d{6}$').hasMatch(otp.trim())) {
      return 'Enter the 6 digit OTP.';
    }
    final phone = state.pendingPhone;
    state = state.copyWith(
      checkingEnrollmentStatus: true,
      clearEnrollmentError: true,
      clearExistingEnrollment: true,
    );

    try {
      final verification = await _otpService.verifyOtp(
        phone: phone,
        otp: otp.trim(),
      );
      final status = WorkerEnrollmentStatus.fromJson(verification);
      if (!status.exists) {
        await _sessionStore.savePhone(phone);
        verifyPhone(phone);
        return null;
      }

      if (status.workerStatus == 'verified') {
        await _sessionStore.savePhone(phone);
        state = state.copyWith(
          phoneVerified: true,
          otpSent: false,
          pendingPhone: '',
          devOtp: '',
          otpAttempts: 0,
          checkingEnrollmentStatus: false,
          clearExistingEnrollment: true,
          application: state.application.copyWith(
            phone: phone,
            fullName: status.fullName,
            status: WorkerReviewStatus.approved,
          ),
        );
        await refreshDashboard();
        return null;
      }

      await _sessionStore.savePhone(phone);
      state = state.copyWith(
        phoneVerified: true,
        otpSent: false,
        pendingPhone: '',
        devOtp: '',
        otpAttempts: 0,
        checkingEnrollmentStatus: false,
        application: state.application.copyWith(phone: phone),
        existingEnrollment: ExistingWorkerEnrollment(
          id: status.id,
          fullName: status.fullName,
          reviewStatus: status.reviewStatus,
          workerStatus: status.workerStatus,
          kycStatus: status.kycStatus,
          submittedAt: status.submittedAt,
        ),
      );
      return null;
    } catch (error) {
      final message = error is WorkerEnrollmentException
          ? error.message
          : error is WorkerOtpException
              ? error.message
              : 'Could not check existing enrollment. Please check your connection.';
      state = state.copyWith(
        checkingEnrollmentStatus: false,
        enrollmentError: message,
      );
      return message;
    }
  }

  void verifyPhone(String phone) {
    state = state.copyWith(
      phoneVerified: true,
      otpSent: false,
      pendingPhone: '',
      devOtp: '',
      otpAttempts: 0,
      application: state.application.copyWith(
        phone: phone,
        status: WorkerReviewStatus.draft,
      ),
    );
  }

  Future<void> restoreSession() async {
    try {
      final phone = await _sessionStore.readPhone();
      if (phone == null || phone.isEmpty) {
        state = state.copyWith(restoringSession: false);
        return;
      }

      state = state.copyWith(
        phoneVerified: true,
        restoringSession: true,
        application: state.application.copyWith(phone: phone),
      );

      final status = await _enrollmentService.statusForPhone(phone);
      if (!status.exists) {
        await _sessionStore.clear();
        state = state.copyWith(
          phoneVerified: false,
          restoringSession: false,
          clearExistingEnrollment: true,
          application: state.application.copyWith(phone: ''),
        );
        return;
      }

      if (status.workerStatus == 'verified') {
        state = state.copyWith(
          restoringSession: false,
          clearExistingEnrollment: true,
          application: state.application.copyWith(
            phone: phone,
            fullName: status.fullName,
            status: WorkerReviewStatus.approved,
          ),
        );
        await refreshDashboard();
        await _restorePreferredAvailability();
        return;
      }

      state = state.copyWith(
        restoringSession: false,
        existingEnrollment: ExistingWorkerEnrollment(
          id: status.id,
          fullName: status.fullName,
          reviewStatus: status.reviewStatus,
          workerStatus: status.workerStatus,
          kycStatus: status.kycStatus,
          submittedAt: status.submittedAt,
        ),
        application: state.application.copyWith(phone: phone),
      );
    } catch (_) {
      state = state.copyWith(
        restoringSession: false,
        phoneVerified: false,
        enrollmentError:
            'Could not restore worker session. Please sign in again.',
      );
    }
  }

  Future<void> clearSession() async {
    final phone = state.application.phone;
    if (phone.isNotEmpty && state.online && state.currentJob == null) {
      try {
        await _dispatchService.publishPresence(phone: phone, online: false);
      } catch (_) {
        // Session clearing must still complete locally. Invalid notification
        // tokens are retired by the backend when delivery is attempted.
      }
    }
    try {
      await _otpService.signOut();
    } catch (_) {
      // Local session clearing must still complete if Firebase sign-out fails.
    }
    await _sessionStore.clear();
    state = const WorkerState(restoringSession: false);
  }

  void selectLanguage(String language) {
    state = state.copyWith(
      onboardingStep: 1,
      application: state.application.copyWith(language: language),
    );
  }

  void saveProfile({
    required String fullName,
    required String age,
    required String city,
    required String workArea,
    required String emergencyContact,
  }) {
    state = state.copyWith(
      onboardingStep: 2,
      application: state.application.copyWith(
        fullName: fullName,
        age: age,
        city: city,
        workArea: workArea,
        emergencyContact: emergencyContact,
      ),
    );
  }

  void toggleEnrollmentType(WorkerEnrollmentType type) {
    final enrollmentTypes = {...state.application.enrollmentTypes};
    var professionalCategories = {...state.application.professionalCategories};

    if (enrollmentTypes.contains(type)) {
      enrollmentTypes.remove(type);
      if (type == WorkerEnrollmentType.professional) {
        professionalCategories = <String>{};
      }
    } else {
      enrollmentTypes.add(type);
    }

    state = state.copyWith(
      application: state.application.copyWith(
        enrollmentTypes: enrollmentTypes,
        professionalCategories: professionalCategories,
      ),
    );
  }

  void addProfessionalCategory(String category) {
    if (!state.application.enrolledAsProfessional) return;
    state = state.copyWith(
      application: state.application.copyWith(
        professionalCategories: {
          ...state.application.professionalCategories,
          category,
        },
      ),
    );
  }

  void removeProfessionalCategory(String category) {
    final updated = {...state.application.professionalCategories}
      ..remove(category);
    state = state.copyWith(
      application: state.application.copyWith(professionalCategories: updated),
    );
  }

  void updateWorkPreferences({
    required String experience,
    required int travelRadiusKm,
  }) {
    state = state.copyWith(
      application: state.application.copyWith(
        experience: experience,
        travelRadiusKm: travelRadiusKm,
      ),
    );
  }

  void goToDocuments() {
    state = state.copyWith(onboardingStep: 4);
  }

  void selectIdType(IndianIdType idType) {
    final documents = {...state.application.documents}
      ..remove(WorkerDocumentType.nationalIdFront)
      ..remove(WorkerDocumentType.nationalIdBack);
    state = state.copyWith(
      application: state.application.copyWith(
        idType: idType,
        documents: documents,
      ),
    );
  }

  void saveDocument(
    WorkerDocumentType type,
    String path, {
    String fileName = '',
    String contentType = 'image/jpeg',
    String contentBase64 = '',
    List<DocumentValidationCheck> validationChecks =
        const <DocumentValidationCheck>[],
    Map<String, String> extractedFields = const <String, String>{},
  }) {
    final documents = {...state.application.documents};
    documents[type] = WorkerDocument(
      type: type,
      path: path,
      fileName: fileName,
      contentType: contentType,
      contentBase64: contentBase64,
      validationChecks: validationChecks,
      extractedFields: extractedFields,
    );
    state = state.copyWith(
      application: state.application.copyWith(documents: documents),
    );
  }

  void goToConsent() {
    state = state.copyWith(onboardingStep: 3);
  }

  void setConsentAccepted(bool accepted) {
    state = state.copyWith(
      application: state.application.copyWith(
        consentAccepted: accepted,
        consentAcceptedAt: accepted ? DateTime.now().toUtc() : null,
        clearConsentAcceptedAt: !accepted,
      ),
    );
  }

  Future<String?> submitForReview() async {
    if (!state.application.canSubmit) return null;
    state = state.copyWith(
      submittingEnrollment: true,
      clearEnrollmentError: true,
    );

    try {
      await _enrollmentService.submit(state.application);
    } catch (error) {
      final message = error is WorkerEnrollmentException
          ? error.message
          : error is WorkerOtpException
              ? error.message
              : 'Could not submit worker enrollment. Please check your connection.';
      state = state.copyWith(
        submittingEnrollment: false,
        enrollmentError: message,
      );
      return message;
    }

    state = state.copyWith(
      onboardingStep: 5,
      online: false,
      submittingEnrollment: false,
      clearEnrollmentError: true,
      application: state.application.copyWith(
        status: WorkerReviewStatus.underReview,
      ),
    );
    return null;
  }

  Future<void> setOnline(bool online) async {
    if (state.updatingAvailability) return;
    if (!online && state.currentJob != null) {
      state = state.copyWith(
        availabilityError:
            'Complete or cancel your active job before going offline.',
        availabilityRequiresSettings: false,
      );
      return;
    }
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    _availabilitySettingsTarget = null;

    state = state.copyWith(
      online: false,
      updatingAvailability: true,
      clearAvailabilityError: true,
    );
    try {
      await _dispatchService.publishPresence(
        phone: state.application.phone,
        online: online,
      );
      state = state.copyWith(
        online: online,
        updatingAvailability: false,
        clearAvailabilityError: true,
      );
      try {
        await _sessionStore.saveOnlinePreference(online);
      } catch (_) {
        // The backend has already confirmed the authoritative availability
        // state. A local storage failure must not incorrectly flip the UI.
      }
      if (online) {
        _startPresenceHeartbeat();
        await checkForPendingJob();
      }
    } catch (error) {
      _setAvailabilityFailure(error);
    }
  }

  void _startPresenceHeartbeat() {
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_refreshConfirmedPresence()),
    );
  }

  Future<void> _refreshConfirmedPresence() async {
    if (!state.online || state.updatingAvailability) return;
    try {
      await _dispatchService.publishPresence(
        phone: state.application.phone,
        online: true,
      );
    } catch (error) {
      _setAvailabilityFailure(error);
    }
  }

  Future<void> refreshPresenceOnResume() async {
    final currentJob = state.currentJob;
    if (currentJob != null) {
      await _refreshJobStatus(currentJob.id);
    }
    await refreshDashboard();
    if (!state.online &&
        !state.updatingAvailability &&
        await _sessionStore.readOnlinePreference()) {
      await setOnline(true);
      return;
    }
    if (state.online && !state.updatingAvailability) {
      await _refreshConfirmedPresence();
      if (state.online) {
        _startPresenceHeartbeat();
        await checkForPendingJob();
      }
    }
  }

  Future<void> refreshDashboard() async {
    final phone = state.application.phone;
    if (phone.isEmpty ||
        state.application.status != WorkerReviewStatus.approved) {
      return;
    }
    try {
      final dashboard = await _dispatchService.dashboard(phone: phone);
      state = state.copyWith(
        earningsToday: dashboard.earningsToday,
        totalEarnings: dashboard.totalEarnings,
        completedJobs: dashboard.completedJobs,
        jobHistory: dashboard.history,
      );
    } catch (_) {
      // Keep the last rendered snapshot during a temporary network failure.
    }
  }

  void _handleTokenRefresh(String token) {
    if (token.isEmpty || !state.online || state.updatingAvailability) return;
    unawaited(_refreshConfirmedPresence());
  }

  Future<void> _restorePreferredAvailability() async {
    if (!await _sessionStore.readOnlinePreference()) return;
    await setOnline(true);
  }

  void _handleJobCancellation(String jobId) {
    final current = state.currentJob;
    if (current == null || current.id != jobId) return;
    _jobStatusTimer?.cancel();
    _jobStatusTimer = null;
    unawaited(_dispatchService.stopAlert());
    state = state.copyWith(
      clearJob: true,
      jobActionInProgress: false,
      clearJobActionError: true,
    );
  }

  void _setAvailabilityFailure(Object error) {
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    final presenceError = error is WorkerPresenceException ? error : null;
    final blockedByActiveJob = presenceError?.code == 'active-job';
    _availabilitySettingsTarget = presenceError?.settingsTarget;
    state = state.copyWith(
      online: blockedByActiveJob,
      updatingAvailability: false,
      availabilityError: presenceError?.message ?? error.toString(),
      availabilityRequiresSettings: presenceError?.settingsTarget != null,
    );
    if (blockedByActiveJob) _startPresenceHeartbeat();
  }

  Future<void> openAvailabilitySettings() async {
    final target = _availabilitySettingsTarget;
    if (target == null) return;
    await _dispatchService.openSettings(target);
  }

  bool receiveJob(WorkerJobRequest job) {
    if (job.id.isEmpty || job.isExpired || state.currentJob != null) {
      return false;
    }
    state = state.copyWith(
      currentJob: job,
      clearJobActionError: true,
    );
    _startJobStatusPolling(job.id);
    return true;
  }

  Future<void> checkForPendingJob() async {
    if (state.application.phone.isEmpty || state.currentJob != null) return;
    try {
      final job = await _dispatchService.pendingJob(
        phone: state.application.phone,
      );
      if (job != null) receiveJob(job);
    } catch (_) {
      // Presence remains online during a temporary offer-recovery failure.
      // The next heartbeat or app resume will retry.
    }
  }

  void generateDemoJob() {
    if (!state.online ||
        state.currentJob != null ||
        state.application.status != WorkerReviewStatus.approved) {
      return;
    }

    final skill = state.application.enrolledAsHelper
        ? 'Helper work'
        : state.application.professionalCategories.first;
    state = state.copyWith(
      currentJob: WorkerJobRequest(
        id: 'job-${DateTime.now().millisecondsSinceEpoch}',
        workType: skill,
        customerArea: 'Sector 62, Noida',
        distanceKm: 1.8,
        durationLabel: '2 Hours',
        payMin: 336,
        payMax: 502,
        notes: 'Customer needs help today. Carry basic tools if needed.',
        status: WorkerJobStatus.offered,
      ),
    );
  }

  Future<void> rejectJob() async {
    final job = state.currentJob;
    if (job == null || state.jobActionInProgress) return;
    state = state.copyWith(
      jobActionInProgress: true,
      clearJobActionError: true,
    );
    try {
      await _dispatchService.respond(
        jobId: job.id,
        phone: state.application.phone,
        accept: false,
      );
      state = state.copyWith(
        clearJob: true,
        jobActionInProgress: false,
        clearJobActionError: true,
      );
    } catch (error) {
      state = state.copyWith(
        jobActionInProgress: false,
        jobActionError: 'Could not reject this job. Please try again.',
      );
    }
  }

  Future<void> acceptJob() async {
    final job = state.currentJob;
    if (job == null || state.jobActionInProgress) return;
    state = state.copyWith(
      jobActionInProgress: true,
      clearJobActionError: true,
    );
    try {
      final accepted = await _dispatchService.respond(
        jobId: job.id,
        phone: state.application.phone,
        accept: true,
      );
      if (accepted) {
        state = state.copyWith(
          currentJob: job.copyWith(status: WorkerJobStatus.accepted),
          jobActionInProgress: false,
          clearJobActionError: true,
        );
        _startJobStatusPolling(job.id);
      } else {
        state = state.copyWith(
          clearJob: true,
          jobActionInProgress: false,
          jobActionError: 'Another worker accepted this job first.',
        );
      }
    } catch (_) {
      state = state.copyWith(
        jobActionInProgress: false,
        jobActionError: 'Could not accept this job. Please try again.',
      );
    }
  }

  Future<void> markArrived() async {
    final job = state.currentJob;
    if (job == null) return;
    try {
      await _dispatchService.updateJobStatus(
        jobId: job.id,
        phone: state.application.phone,
        status: 'arrived',
      );
      state = state.copyWith(
          currentJob: job.copyWith(status: WorkerJobStatus.arrived));
    } catch (error) {
      state = state.copyWith(enrollmentError: error.toString());
    }
  }

  Future<void> startWork() async {
    final job = state.currentJob;
    if (job == null) return;
    try {
      await _dispatchService.updateJobStatus(
        jobId: job.id,
        phone: state.application.phone,
        status: 'started',
      );
      state = state.copyWith(
          currentJob: job.copyWith(status: WorkerJobStatus.started));
    } catch (error) {
      state = state.copyWith(enrollmentError: error.toString());
    }
  }

  Future<void> completeWork() async {
    final job = state.currentJob;
    if (job == null ||
        job.status != WorkerJobStatus.started ||
        state.jobActionInProgress) {
      return;
    }
    state = state.copyWith(
      jobActionInProgress: true,
      clearJobActionError: true,
    );
    try {
      await _dispatchService.updateJobStatus(
        jobId: job.id,
        phone: state.application.phone,
        status: 'completion_requested',
      );
      state = state.copyWith(
        currentJob: job.copyWith(status: WorkerJobStatus.completionRequested),
        jobActionInProgress: false,
        clearJobActionError: true,
      );
    } catch (_) {
      state = state.copyWith(
        jobActionInProgress: false,
        jobActionError:
            'Could not request customer confirmation. Please try again.',
      );
    }
  }

  Future<void> cancelCurrentJob() async {
    final job = state.currentJob;
    if (job == null ||
        state.jobActionInProgress ||
        job.status == WorkerJobStatus.started ||
        job.status == WorkerJobStatus.completed) {
      return;
    }
    state = state.copyWith(
      jobActionInProgress: true,
      clearJobActionError: true,
    );
    try {
      await _dispatchService.updateJobStatus(
        jobId: job.id,
        phone: state.application.phone,
        status: 'cancelled',
      );
      _jobStatusTimer?.cancel();
      _jobStatusTimer = null;
      state = state.copyWith(
        clearJob: true,
        jobActionInProgress: false,
        clearJobActionError: true,
      );
    } catch (_) {
      state = state.copyWith(
        jobActionInProgress: false,
        jobActionError: 'Could not cancel this job. Please try again.',
      );
    }
  }

  void _startJobStatusPolling(String jobId) {
    _jobStatusTimer?.cancel();
    _jobStatusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refreshJobStatus(jobId)),
    );
    unawaited(_refreshJobStatus(jobId));
  }

  Future<void> _refreshJobStatus(String jobId) async {
    if (_jobStatusRefreshInFlight) return;
    final current = state.currentJob;
    if (current == null || current.id != jobId) {
      _jobStatusTimer?.cancel();
      _jobStatusTimer = null;
      return;
    }
    _jobStatusRefreshInFlight = true;
    try {
      final remote = await _dispatchService.jobStatus(
        jobId: jobId,
        phone: state.application.phone,
      );
      final status = remote['status'] as String? ?? 'unknown';
      final offerStatus = remote['offerStatus'] as String? ?? 'unknown';
      final isAcceptedWorker = remote['isAcceptedWorker'] == true;
      if (status == 'completed' && isAcceptedWorker) {
        await _dispatchService.stopAlert();
        _jobStatusTimer?.cancel();
        _jobStatusTimer = null;
        state = state.copyWith(
          clearJob: true,
          clearJobActionError: true,
        );
        await refreshDashboard();
        return;
      }
      if (status == 'completion_requested' &&
          current.status != WorkerJobStatus.completionRequested) {
        state = state.copyWith(
          currentJob:
              current.copyWith(status: WorkerJobStatus.completionRequested),
        );
      } else if (status == 'started' &&
          current.status == WorkerJobStatus.completionRequested) {
        state = state.copyWith(
          currentJob: current.copyWith(status: WorkerJobStatus.started),
          jobActionError:
              'The customer marked the work as remaining. Complete it and request confirmation again.',
        );
      }
      final isTerminal = status == 'cancelled' || status == 'expired';
      final wasTakenByAnotherWorker = status == 'accepted' && !isAcceptedWorker;
      final offerIsClosed = offerStatus == 'rejected' ||
          offerStatus == 'cancelled' ||
          (offerStatus == 'expired' && !isAcceptedWorker);
      if (isTerminal || wasTakenByAnotherWorker || offerIsClosed) {
        await _dispatchService.stopAlert();
        _jobStatusTimer?.cancel();
        _jobStatusTimer = null;
        state = state.copyWith(
          clearJob: true,
          jobActionInProgress: false,
          clearJobActionError: true,
        );
      }
    } catch (_) {
      // Keep the current job visible during temporary network failures.
    } finally {
      _jobStatusRefreshInFlight = false;
    }
  }

  @override
  void dispose() {
    _presenceHeartbeat?.cancel();
    _jobStatusTimer?.cancel();
    unawaited(_tokenRefreshSubscription.cancel());
    unawaited(_jobCancellationSubscription.cancel());
    unawaited(_dispatchService.stopAlert());
    super.dispose();
  }
}
