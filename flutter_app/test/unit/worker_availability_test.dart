import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gofer/models/worker_models.dart';
import 'package:gofer/providers/worker_provider.dart';
import 'package:gofer/services/worker_dispatch_service.dart';
import 'package:gofer/services/worker_enrollment_service.dart';
import 'package:gofer/services/worker_otp_service.dart';
import 'package:gofer/services/worker_session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _FakeDispatchGateway implements WorkerDispatchGateway {
  final StreamController<String> tokenController =
      StreamController<String>.broadcast();
  final StreamController<String> cancellationController =
      StreamController<String>.broadcast();
  final List<bool> presenceCalls = [];
  Completer<void>? presenceCompleter;
  Object? presenceError;
  WorkerSettingsTarget? openedSettings;
  bool Function(WorkerJobRequest job)? handler;
  WorkerJobRequest? pending;
  int pendingJobCalls = 0;
  bool respondResult = true;
  Object? respondError;
  final List<String> jobStatusUpdates = [];
  Map<String, dynamic> statusResponse = const {};
  WorkerDashboardSnapshot dashboardSnapshot = const WorkerDashboardSnapshot(
    earningsToday: 0,
    totalEarnings: 0,
    completedJobs: 0,
    history: [],
  );
  int dashboardCalls = 0;

  @override
  Stream<String> get tokenRefreshes => tokenController.stream;

  @override
  Stream<String> get cancelledJobIds => cancellationController.stream;

  @override
  set onJob(bool Function(WorkerJobRequest job) value) => handler = value;

  @override
  Future<void> publishPresence({
    required String phone,
    required bool online,
  }) async {
    presenceCalls.add(online);
    final error = presenceError;
    if (error != null) throw error;
    final completer = presenceCompleter;
    if (completer != null) await completer.future;
  }

  @override
  Future<bool> openSettings(WorkerSettingsTarget target) async {
    openedSettings = target;
    return true;
  }

  @override
  Future<Map<String, dynamic>> jobStatus({
    required String jobId,
    required String phone,
  }) async =>
      statusResponse;

  @override
  Future<WorkerJobRequest?> pendingJob({required String phone}) async {
    pendingJobCalls += 1;
    return pending;
  }

  @override
  Future<WorkerDashboardSnapshot> dashboard({required String phone}) async {
    dashboardCalls += 1;
    return dashboardSnapshot;
  }

  @override
  Future<bool> respond({
    required String jobId,
    required String phone,
    required bool accept,
  }) async {
    if (respondError != null) throw respondError!;
    return accept && respondResult;
  }

  @override
  Future<void> stopAlert() async {}

  @override
  Future<void> updateJobStatus({
    required String jobId,
    required String phone,
    required String status,
  }) async {
    jobStatusUpdates.add(status);
  }

  Future<void> close() async {
    await tokenController.close();
    await cancellationController.close();
  }
}

class _FakeEnrollmentService extends WorkerEnrollmentService {
  WorkerEnrollmentStatus status = const WorkerEnrollmentStatus(exists: false);
  Object? error;

  @override
  Future<WorkerEnrollmentStatus> statusForPhone(String phone) async {
    if (error != null) throw error!;
    return status;
  }
}

class _FakeSessionStore extends WorkerSessionStore {
  String? savedPhone;
  bool onlinePreference = false;

  @override
  Future<void> savePhone(String phone) async {
    savedPhone = phone;
  }

  @override
  Future<String?> readPhone() async => savedPhone;

  @override
  Future<bool> readOnlinePreference() async => onlinePreference;

  @override
  Future<void> saveOnlinePreference(bool online) async {
    onlinePreference = online;
  }

  @override
  Future<void> clear() async {
    savedPhone = null;
    onlinePreference = false;
  }
}

class _FakeOtpService extends WorkerOtpService {
  _FakeOtpService() : super(auth: _MockFirebaseAuth());

  final _autoVerificationController =
      StreamController<WorkerOtpAutoVerification>.broadcast();
  int sendCalls = 0;
  bool automaticallyVerify = false;
  int verifyCalls = 0;
  String? verifiedOtp;
  Map<String, dynamic> verifyResponse = const {'exists': false};
  Object? verifyError;

  @override
  Future<bool> hasAuthenticatedSession(String phone) async => true;

  @override
  Stream<WorkerOtpAutoVerification> get autoVerifications =>
      _autoVerificationController.stream;

  void completeAutomaticVerification(String phone, {String? smsCode}) {
    _autoVerificationController.add(
      WorkerOtpAutoVerification(phone: phone, smsCode: smsCode),
    );
  }

  @override
  Future<WorkerOtpSendResult> sendOtp(String phone) async {
    sendCalls += 1;
    return WorkerOtpSendResult(
      expiresIn: 300,
      automaticallyVerified: automaticallyVerify,
      smsCode: automaticallyVerify ? '123456' : null,
    );
  }

  @override
  Future<Map<String, dynamic>> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    verifyCalls += 1;
    verifiedOtp = otp;
    if (verifyError != null) throw verifyError!;
    return verifyResponse;
  }
}

WorkerController _controller(
  _FakeDispatchGateway gateway, {
  WorkerEnrollmentService? enrollmentService,
  WorkerSessionStore? sessionStore,
  WorkerOtpService? otpService,
}) {
  return WorkerController(
    enrollmentService ?? WorkerEnrollmentService(),
    sessionStore ?? _FakeSessionStore(),
    otpService: otpService ?? _FakeOtpService(),
    dispatchService: gateway,
    restoreSessionOnStart: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blocks repeated OTP sends during the 30 second cooldown', () async {
    final gateway = _FakeDispatchGateway();
    final otpService = _FakeOtpService();
    final controller = _controller(gateway, otpService: otpService);

    expect(await controller.requestOtp('9876543210'), isNull);
    final secondResult = await controller.requestOtp('9876543210');

    expect(secondResult, contains('Please wait'));
    expect(otpService.sendCalls, 1);
    expect(controller.otpResendSecondsRemaining, inInclusiveRange(1, 30));
    controller.dispose();
    await gateway.close();
  });

  test('completes login when Firebase automatically retrieves the OTP',
      () async {
    final gateway = _FakeDispatchGateway();
    final otpService = _FakeOtpService()..automaticallyVerify = true;
    final controller = _controller(gateway, otpService: otpService);

    expect(await controller.requestOtp('9876543210'), isNull);

    expect(otpService.verifyCalls, 1);
    expect(otpService.verifiedOtp, '123456');
    expect(controller.state.phoneVerified, isTrue);
    expect(controller.state.application.phone, '9876543210');
    controller.dispose();
    await gateway.close();
  });

  test('reacts to automatic OTP retrieval after the SMS has been sent',
      () async {
    final gateway = _FakeDispatchGateway();
    final otpService = _FakeOtpService();
    final controller = _controller(gateway, otpService: otpService);

    expect(await controller.requestOtp('9876543210'), isNull);
    otpService.completeAutomaticVerification(
      '9876543210',
      smsCode: '654321',
    );
    for (var attempt = 0;
        attempt < 10 && !controller.state.phoneVerified;
        attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(otpService.verifyCalls, 1);
    expect(otpService.verifiedOtp, '654321');
    expect(controller.state.phoneVerified, isTrue);
    controller.dispose();
    await gateway.close();
  });

  test('reads nested worker-service errors and includes the request reference',
      () {
    final response = http.Response(
      '{"success":false,"error":{"message":"Database presence update failed","statusCode":500}}',
      500,
      headers: {'x-request-id': 'request-123'},
    );

    expect(
      workerServiceFailureMessage(response),
      'Database presence update failed (HTTP 500, reference request-123)',
    );
  });

  test('keeps compatibility with legacy top-level worker-service errors', () {
    final response = http.Response(
      '{"success":false,"message":"Verified worker not found"}',
      404,
    );

    expect(
      workerServiceFailureMessage(response),
      'Verified worker not found (HTTP 404)',
    );
  });

  test('reports gateway failures even when the response is not JSON', () {
    final response = http.Response('<html>Bad gateway</html>', 502);

    expect(
      workerServiceFailureMessage(response),
      'Worker service request failed (HTTP 502)',
    );
  });

  test('does not show online until backend presence is confirmed', () async {
    final gateway = _FakeDispatchGateway();
    gateway.presenceCompleter = Completer<void>();
    final controller = _controller(gateway);

    final update = controller.setOnline(true);
    expect(controller.state.online, isFalse);
    expect(controller.state.updatingAvailability, isTrue);

    gateway.presenceCompleter!.complete();
    await update;

    expect(controller.state.online, isTrue);
    expect(controller.state.updatingAvailability, isFalse);
    expect(gateway.presenceCalls, [true]);
    controller.dispose();
    await gateway.close();
  });

  test('permission failure keeps worker offline and exposes settings action',
      () async {
    final gateway = _FakeDispatchGateway()
      ..presenceError = const WorkerPresenceException(
        'notification-permission-denied',
        'Notifications are blocked.',
        settingsTarget: WorkerSettingsTarget.app,
      );
    final controller = _controller(gateway);

    await controller.setOnline(true);

    expect(controller.state.online, isFalse);
    expect(controller.state.updatingAvailability, isFalse);
    expect(controller.state.availabilityError, 'Notifications are blocked.');
    expect(controller.state.availabilityRequiresSettings, isTrue);

    await controller.openAvailabilitySettings();
    expect(gateway.openedSettings, WorkerSettingsTarget.app);
    controller.dispose();
    await gateway.close();
  });

  test('location-service failure opens location settings', () async {
    final gateway = _FakeDispatchGateway()
      ..presenceError = const WorkerPresenceException(
        'location-services-disabled',
        'Turn on location services.',
        settingsTarget: WorkerSettingsTarget.locationServices,
      );
    final controller = _controller(gateway);

    await controller.setOnline(true);
    await controller.openAvailabilitySettings();

    expect(controller.state.online, isFalse);
    expect(gateway.openedSettings, WorkerSettingsTarget.locationServices);
    controller.dispose();
    await gateway.close();
  });

  test('backend failure never leaves an optimistic online state', () async {
    final gateway = _FakeDispatchGateway()
      ..presenceError = const WorkerPresenceException(
        'presence-update-failed',
        'Backend unavailable.',
      );
    final controller = _controller(gateway);

    await controller.setOnline(true);

    expect(controller.state.online, isFalse);
    expect(controller.state.availabilityError, 'Backend unavailable.');
    expect(controller.state.availabilityRequiresSettings, isFalse);
    controller.dispose();
    await gateway.close();
  });

  test('going offline remains fail-closed when backend update fails', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    await controller.setOnline(true);
    expect(controller.state.online, isTrue);

    gateway.presenceError = const WorkerPresenceException(
      'presence-update-failed',
      'Backend unavailable.',
    );
    await controller.setOnline(false);

    expect(controller.state.online, isFalse);
    expect(gateway.presenceCalls, [true, false]);
    controller.dispose();
    await gateway.close();
  });

  test('FCM token refresh republishes confirmed online presence', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    await controller.setOnline(true);

    gateway.tokenController.add('fresh-token');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(gateway.presenceCalls, [true, true]);
    expect(controller.state.online, isTrue);
    controller.dispose();
    await gateway.close();
  });

  test('app resume republishes confirmed online presence', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    await controller.setOnline(true);

    await controller.refreshPresenceOnResume();

    expect(gateway.presenceCalls, [true, true]);
    expect(controller.state.online, isTrue);
    controller.dispose();
    await gateway.close();
  });

  test('app resume is ignored while worker is offline', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);

    await controller.refreshPresenceOnResume();

    expect(gateway.presenceCalls, isEmpty);
    controller.dispose();
    await gateway.close();
  });

  test('FCM token refresh is ignored while worker is offline', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);

    gateway.tokenController.add('fresh-token');
    await Future<void>.delayed(Duration.zero);

    expect(gateway.presenceCalls, isEmpty);
    expect(controller.state.online, isFalse);
    controller.dispose();
    await gateway.close();
  });

  test('going online recovers a pending backend offer', () async {
    final gateway = _FakeDispatchGateway()
      ..pending = WorkerJobRequest(
        id: 'job-1',
        workType: 'Cleaning',
        customerArea: 'Sector 62',
        distanceKm: 1.2,
        durationLabel: 'New request',
        payMin: 500,
        payMax: 500,
        notes: 'Bring supplies',
        status: WorkerJobStatus.offered,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      );
    final controller = _controller(gateway);
    controller.verifyPhone('9876543210');

    await controller.setOnline(true);

    expect(gateway.pendingJobCalls, 1);
    expect(controller.state.currentJob?.id, 'job-1');
    controller.dispose();
    await gateway.close();
  });

  test('a valid push offer is retained even after process state restoration',
      () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    final received = controller.receiveJob(
      WorkerJobRequest(
        id: 'job-restored',
        workType: 'Helper work',
        customerArea: 'Noida',
        distanceKm: 0.8,
        durationLabel: 'New request',
        payMin: 400,
        payMax: 400,
        notes: '',
        status: WorkerJobStatus.offered,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    );

    expect(received, isTrue);
    expect(controller.state.currentJob?.id, 'job-restored');
    controller.dispose();
    await gateway.close();
  });

  test('failed accept keeps the offer visible and exposes a retry error',
      () async {
    final gateway = _FakeDispatchGateway()
      ..respondError = StateError('network');
    final controller = _controller(gateway);
    controller.verifyPhone('9876543210');
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'job-retry',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'New request',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.offered,
      ),
    );

    await controller.acceptJob();

    expect(controller.state.currentJob?.id, 'job-retry');
    expect(controller.state.jobActionInProgress, isFalse);
    expect(controller.state.jobActionError, contains('try again'));
    controller.dispose();
    await gateway.close();
  });

  test('production enrollment requests use the deployed backend by default',
      () async {
    Uri? requestedUri;
    final service = WorkerEnrollmentService(
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response('{"success":true,"exists":false}', 200);
      }),
    );

    await service.statusForPhone('9876543210');

    expect(requestedUri?.origin, 'https://gofer-backend.onrender.com');
    expect(requestedUri?.path, '/api/workers/enrollments/status');
  });

  test('enrollment lookup retries a transient first request failure', () async {
    var attempts = 0;
    final service = WorkerEnrollmentService(
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        attempts += 1;
        if (attempts == 1) {
          throw TimeoutException('cold start');
        }
        return http.Response(
          '{"success":true,"exists":true,"enrollment":{"id":"worker-1","fullName":"Sabyasachi Nishant","reviewStatus":"approved","workerStatus":"verified","kycStatus":"verified"}}',
          200,
        );
      }),
    );

    final status = await service.statusForPhone('9876543210');

    expect(attempts, 2);
    expect(status.exists, isTrue);
    expect(status.workerStatus, 'verified');
  });

  test('enrollment lookup reports nested backend errors after retries',
      () async {
    final service = WorkerEnrollmentService(
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        return http.Response(
          '{"success":false,"error":{"message":"Database unavailable","statusCode":500}}',
          500,
        );
      }),
    );

    expect(
      () => service.statusForPhone('9876543210'),
      throwsA(
        isA<WorkerEnrollmentException>().having(
          (error) => error.message,
          'message',
          'Database unavailable',
        ),
      ),
    );
  });

  test('failed enrollment lookup remains on login with a retryable error',
      () async {
    final gateway = _FakeDispatchGateway();
    final otpService = _FakeOtpService()
      ..verifyError = const WorkerEnrollmentException('offline');
    final controller = _controller(
      gateway,
      otpService: otpService,
      sessionStore: _FakeSessionStore(),
    );
    await controller.requestOtp('9876543210');

    final error = await controller.verifyOtpAndCheckEnrollment('123456');

    expect(error, 'offline');
    expect(controller.state.phoneVerified, isFalse);
    expect(controller.state.otpSent, isTrue);
    expect(controller.state.pendingPhone, '9876543210');
    expect(controller.state.checkingEnrollmentStatus, isFalse);
    controller.dispose();
    await gateway.close();
  });

  test('verified enrollment redirects only after backend confirmation',
      () async {
    final gateway = _FakeDispatchGateway()
      ..dashboardSnapshot = WorkerDashboardSnapshot(
        earningsToday: 179,
        totalEarnings: 512,
        completedJobs: 3,
        history: [
          WorkerJobHistoryItem(
            id: 'job-1',
            workType: 'Cleaning',
            customerArea: 'Danapur',
            amount: 179,
            completedAt: DateTime(2026, 7, 20),
          ),
        ],
      );
    final otpService = _FakeOtpService()
      ..verifyResponse = const {
        'exists': true,
        'enrollment': {
          'id': 'worker-1',
          'fullName': 'Sabyasachi Nishant',
          'reviewStatus': 'approved',
          'workerStatus': 'verified',
          'kycStatus': 'verified',
        },
      };
    final session = _FakeSessionStore();
    final controller = _controller(
      gateway,
      otpService: otpService,
      sessionStore: session,
    );
    await controller.requestOtp('9876543210');

    final error = await controller.verifyOtpAndCheckEnrollment('123456');

    expect(error, isNull);
    expect(controller.state.phoneVerified, isTrue);
    expect(controller.state.application.status, WorkerReviewStatus.approved);
    expect(controller.state.application.fullName, 'Sabyasachi Nishant');
    expect(controller.state.earningsToday, 179);
    expect(controller.state.totalEarnings, 512);
    expect(controller.state.completedJobs, 3);
    expect(controller.state.jobHistory.single.id, 'job-1');
    expect(gateway.dashboardCalls, 1);
    expect(session.savedPhone, '9876543210');
    controller.dispose();
    await gateway.close();
  });

  test('restoring a verified session reloads persisted worker history',
      () async {
    final gateway = _FakeDispatchGateway()
      ..dashboardSnapshot = WorkerDashboardSnapshot(
        earningsToday: 400,
        totalEarnings: 900,
        completedJobs: 2,
        history: [
          WorkerJobHistoryItem(
            id: 'restored-job',
            workType: 'Helper work',
            customerArea: 'Noida',
            amount: 400,
            completedAt: DateTime(2026, 7, 19),
          ),
        ],
      );
    final enrollment = _FakeEnrollmentService()
      ..status = const WorkerEnrollmentStatus(
        exists: true,
        id: 'worker-1',
        fullName: 'Sabyasachi Nishant',
        reviewStatus: 'approved',
        workerStatus: 'verified',
        kycStatus: 'verified',
      );
    final session = _FakeSessionStore()..savedPhone = '9876543210';
    final controller = _controller(
      gateway,
      enrollmentService: enrollment,
      sessionStore: session,
    );

    await controller.restoreSession();

    expect(controller.state.restoringSession, isFalse);
    expect(controller.state.earningsToday, 400);
    expect(controller.state.totalEarnings, 900);
    expect(controller.state.completedJobs, 2);
    expect(controller.state.jobHistory.single.id, 'restored-job');
    controller.dispose();
    await gateway.close();
  });

  test('restoring a session without an enrollment resumes onboarding',
      () async {
    final gateway = _FakeDispatchGateway();
    final session = _FakeSessionStore()..savedPhone = '9876543210';
    final controller = _controller(
      gateway,
      enrollmentService: _FakeEnrollmentService(),
      sessionStore: session,
    );

    await controller.restoreSession();

    expect(controller.state.restoringSession, isFalse);
    expect(controller.state.phoneVerified, isTrue);
    expect(controller.state.application.phone, '9876543210');
    expect(controller.state.application.status, WorkerReviewStatus.draft);
    expect(session.savedPhone, '9876543210');
    controller.dispose();
    await gateway.close();
  });

  test('temporary restore failure keeps the trusted session for retry',
      () async {
    final gateway = _FakeDispatchGateway();
    final enrollment = _FakeEnrollmentService()
      ..error = const WorkerEnrollmentException('offline');
    final session = _FakeSessionStore()..savedPhone = '9876543210';
    final controller = _controller(
      gateway,
      enrollmentService: enrollment,
      sessionStore: session,
    );

    await controller.restoreSession();

    expect(controller.state.phoneVerified, isTrue);
    expect(controller.state.restoringSession, isTrue);
    expect(controller.state.enrollmentError, contains('still valid'));
    expect(session.savedPhone, '9876543210');
    controller.dispose();
    await gateway.close();
  });

  test('onboarding back moves to the previous enrollment step', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.verifyPhone('9876543210');
    controller.selectLanguage('English');
    controller.saveProfile(
      fullName: 'Test Worker',
      age: '28',
      city: 'Patna',
      workArea: 'Danapur',
      emergencyContact: '9876543211',
    );

    expect(controller.state.onboardingStep, 2);
    expect(controller.goBackInOnboarding(), isTrue);
    expect(controller.state.onboardingStep, 1);
    expect(controller.goBackInOnboarding(), isTrue);
    expect(controller.state.onboardingStep, 0);
    expect(controller.goBackInOnboarding(), isFalse);
    controller.dispose();
    await gateway.close();
  });

  test('restoring a verified session restores the explicit online choice',
      () async {
    final gateway = _FakeDispatchGateway();
    final enrollment = _FakeEnrollmentService()
      ..status = const WorkerEnrollmentStatus(
        exists: true,
        id: 'worker-1',
        fullName: 'Ready Worker',
        reviewStatus: 'approved',
        workerStatus: 'verified',
        kycStatus: 'verified',
      );
    final session = _FakeSessionStore()
      ..savedPhone = '9876543210'
      ..onlinePreference = true;
    final controller = _controller(
      gateway,
      enrollmentService: enrollment,
      sessionStore: session,
    );

    await controller.restoreSession();

    expect(controller.state.online, isTrue);
    expect(gateway.presenceCalls, [true]);
    expect(session.onlinePreference, isTrue);
    controller.dispose();
    await gateway.close();
  });

  test('accepted jobs remain active after the original offer expiry', () {
    final job = WorkerJobRequest(
      id: 'accepted-job',
      workType: 'Cleaning',
      customerArea: 'Noida',
      distanceKm: 1,
      durationLabel: 'New request',
      payMin: 500,
      payMax: 500,
      notes: '',
      status: WorkerJobStatus.accepted,
      expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );

    expect(job.isExpired, isFalse);
  });

  test('assigned worker cannot switch offline until the job is resolved',
      () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    await controller.setOnline(true);
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'active-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.accepted,
      ),
    );

    await controller.setOnline(false);

    expect(controller.state.online, isTrue);
    expect(gateway.presenceCalls, [true]);
    expect(controller.state.availabilityError, contains('active job'));
    controller.dispose();
    await gateway.close();
  });

  test('cancelling an accepted job releases it from worker state', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'active-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.accepted,
      ),
    );

    await controller.cancelCurrentJob();

    expect(gateway.jobStatusUpdates, ['cancelled']);
    expect(controller.state.currentJob, isNull);
    controller.dispose();
    await gateway.close();
  });

  test('customer cancellation immediately removes the matching job', () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'customer-cancelled-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.accepted,
      ),
    );

    gateway.cancellationController.add('customer-cancelled-job');
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.currentJob, isNull);
    expect(controller.state.jobActionInProgress, isFalse);
    controller.dispose();
    await gateway.close();
  });

  test('cancellation for another job does not disturb the active job',
      () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'active-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.accepted,
      ),
    );

    gateway.cancellationController.add('different-job');
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.currentJob?.id, 'active-job');
    controller.dispose();
    await gateway.close();
  });

  test('cancelled offer recovery releases worker after a lost response',
      () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.verifyPhone('9876543210');
    gateway.statusResponse = {
      'status': 'offered',
      'offerStatus': 'cancelled',
      'isAcceptedWorker': false,
    };
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'cancelled-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.accepted,
      ),
    );

    await Future<void>.delayed(const Duration(seconds: 4));

    expect(controller.state.currentJob, isNull);
    controller.dispose();
    await gateway.close();
  });

  test('worker completion requests customer approval and keeps job active',
      () async {
    final gateway = _FakeDispatchGateway();
    final controller = _controller(gateway);
    controller.verifyPhone('9876543210');
    controller.receiveJob(
      const WorkerJobRequest(
        id: 'started-job',
        workType: 'Cleaning',
        customerArea: 'Noida',
        distanceKm: 1,
        durationLabel: 'Current job',
        payMin: 500,
        payMax: 500,
        notes: '',
        status: WorkerJobStatus.started,
      ),
    );

    await controller.completeWork();

    expect(gateway.jobStatusUpdates, ['completion_requested']);
    expect(
      controller.state.currentJob?.status,
      WorkerJobStatus.completionRequested,
    );
    expect(controller.state.completedJobs, 0);
    expect(controller.state.earningsToday, 0);
    controller.dispose();
    await gateway.close();
  });

  test('completion-request status parses backend snake case safely', () {
    final job = WorkerJobRequest.fromJson(const {
      'id': 'job-1',
      'status': 'completion_requested',
      'budget': 500,
    });

    expect(job.status, WorkerJobStatus.completionRequested);
  });
}
