import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/worker_models.dart';

String workerServiceFailureMessage(http.Response response) {
  String? message;
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final directMessage = decoded['message'];
      final nestedError = decoded['error'];
      if (directMessage is String && directMessage.trim().isNotEmpty) {
        message = directMessage.trim();
      } else if (nestedError is Map) {
        final nestedMessage = nestedError['message'];
        if (nestedMessage is String && nestedMessage.trim().isNotEmpty) {
          message = nestedMessage.trim();
        }
      }
    }
  } on FormatException {
    // Gateways and proxies can return HTML or an empty response during outages.
  }

  final requestId = response.headers['x-request-id'];
  final reference =
      requestId == null || requestId.isEmpty ? '' : ', reference $requestId';
  return '${message ?? 'Worker service request failed'} '
      '(HTTP ${response.statusCode}$reference)';
}

enum WorkerSettingsTarget { app, locationServices }

class WorkerAlertSettings {
  const WorkerAlertSettings({
    required this.notificationPolicyAccess,
    required this.channelCanBypassDnd,
    required this.channelEnabled,
  });

  final bool notificationPolicyAccess;
  final bool channelCanBypassDnd;
  final bool channelEnabled;

  bool get urgentSoundEnabled =>
      notificationPolicyAccess && channelCanBypassDnd && channelEnabled;
}

class WorkerPresenceException implements Exception {
  const WorkerPresenceException(
    this.code,
    this.message, {
    this.settingsTarget,
  });

  final String code;
  final String message;
  final WorkerSettingsTarget? settingsTarget;

  @override
  String toString() => message;
}

abstract interface class WorkerDispatchGateway {
  Stream<String> get tokenRefreshes;
  Stream<String> get cancelledJobIds;

  set onJob(bool Function(WorkerJobRequest job) handler);

  Future<void> publishPresence({
    required String phone,
    required bool online,
  });

  Future<bool> respond({
    required String jobId,
    required String phone,
    required bool accept,
  });

  Future<Map<String, dynamic>> jobStatus({
    required String jobId,
    required String phone,
  });

  Future<WorkerJobRequest?> pendingJob({required String phone});

  Future<WorkerDashboardSnapshot> dashboard({required String phone});

  Future<void> updateJobStatus({
    required String jobId,
    required String phone,
    required String status,
  });

  Future<void> stopAlert();

  Future<bool> openSettings(WorkerSettingsTarget target);
}

class WorkerDispatchService implements WorkerDispatchGateway {
  WorkerDispatchService._();
  static final instance = WorkerDispatchService._();

  static const _channel = MethodChannel('com.gofer.worker/job_alert');
  static const _configuredBaseUrl = String.fromEnvironment(
    'GOFER_WORKER_API_BASE_URL',
    defaultValue: 'https://gofer-backend.onrender.com',
  );
  static const _tokenResetBuildKey = 'gofer_worker_fcm_reset_build';
  static const _pendingJobKey = 'gofer_worker_pending_job';
  static const _cancelledJobsKey = 'gofer_worker_cancelled_jobs';
  static const _cancelledJobRetention = Duration(hours: 24);
  static const _dashboardCachePrefix = 'gofer_worker_dashboard_';

  final _client = http.Client();
  final _cancelledJobs = StreamController<String>.broadcast();
  WorkerJobRequest? _pendingJob;
  bool Function(WorkerJobRequest job)? _handler;

  @override
  Stream<String> get tokenRefreshes {
    if (kIsWeb) return const Stream<String>.empty();
    return FirebaseMessaging.instance.onTokenRefresh;
  }

  @override
  Stream<String> get cancelledJobIds => _cancelledJobs.stream;

  @override
  set onJob(bool Function(WorkerJobRequest job) handler) {
    _handler = handler;
    final pending = _pendingJob;
    if (pending != null) {
      _pendingJob = null;
      if (!handler(pending)) unawaited(stopAlert());
    }
  }

  Future<void> initialize() async {
    if (kIsWeb) return;
    final messaging = FirebaseMessaging.instance;
    FirebaseMessaging.onMessage.listen(_handleMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _handleMessage(initial);
    } else {
      final restored = await _readStoredJob();
      if (restored != null && !restored.isExpired) {
        _pendingJob = restored;
      } else if (restored != null) {
        await _clearStoredJob();
      }
    }
  }

  static Future<void> persistBackgroundMessage(
    Map<String, dynamic> data,
  ) async {
    if (data['type'] == 'job_cancelled') {
      final jobId = data['jobId']?.toString() ?? '';
      if (jobId.isEmpty) return;
      await _rememberCancelledJob(jobId);
      await _clearStoredJobIfMatching(jobId);
      return;
    }
    if (data['type'] != 'job_offer') return;
    final job = WorkerJobRequest.fromJson(data);
    if (job.id.isEmpty || job.isExpired || await _wasJobCancelled(job.id)) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_pendingJobKey, jsonEncode(job.toJson()));
  }

  @override
  Future<void> publishPresence({
    required String phone,
    required bool online,
  }) async {
    if (phone.isEmpty) {
      throw const WorkerPresenceException(
        'missing-phone',
        'Sign in again before going online.',
      );
    }
    if (kIsWeb) return;
    String? token;
    Position? position;
    try {
      if (online) {
        await _ensureNotificationPermission();
        final locationEnabled = await Geolocator.isLocationServiceEnabled();
        if (!locationEnabled) {
          throw const WorkerPresenceException(
            'location-services-disabled',
            'Turn on phone location services before going online.',
            settingsTarget: WorkerSettingsTarget.locationServices,
          );
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.deniedForever) {
          throw const WorkerPresenceException(
            'location-permission-permanently-denied',
            'Location permission is blocked. Allow precise location in app settings.',
            settingsTarget: WorkerSettingsTarget.app,
          );
        }
        if (permission != LocationPermission.always &&
            permission != LocationPermission.whileInUse) {
          throw const WorkerPresenceException(
            'location-permission-denied',
            'Location permission is required to receive nearby jobs.',
            settingsTarget: WorkerSettingsTarget.app,
          );
        }
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 20),
          ),
        );
        token = await _onlineToken();
      } else {
        token = await FirebaseMessaging.instance.getToken();
      }
      final response = await _post('/api/workers/presence', {
        'phone': phone,
        'online': online,
        'fcmToken': token,
        'platform':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        'latitude': position?.latitude,
        'longitude': position?.longitude,
      });
      final presence = response['presence'];
      if (presence is Map && presence['blockedByActiveJob'] == true) {
        throw const WorkerPresenceException(
          'active-job',
          'Complete or cancel your active job before going offline.',
        );
      }
    } on WorkerPresenceException {
      rethrow;
    } catch (error) {
      throw WorkerPresenceException(
        'presence-update-failed',
        'Could not confirm availability with Gofer: $error',
      );
    }
  }

  Future<void> _ensureNotificationPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      throw const WorkerPresenceException(
        'notification-permission-denied',
        'Notifications are blocked. Allow Gofer Worker notifications in app settings.',
        settingsTarget: WorkerSettingsTarget.app,
      );
    }
  }

  Future<String> _onlineToken() async {
    final messaging = FirebaseMessaging.instance;
    final packageInfo = await PackageInfo.fromPlatform();
    final buildSignature = '${packageInfo.version}+${packageInfo.buildNumber}';
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_tokenResetBuildKey) != buildSignature) {
      await messaging.deleteToken();
      await preferences.setString(_tokenResetBuildKey, buildSignature);
    }
    final token = await messaging.getToken();
    if (token == null || token.trim().isEmpty) {
      throw const WorkerPresenceException(
        'notification-token-unavailable',
        'This phone could not register for job notifications. Check Google Play services and try again.',
        settingsTarget: WorkerSettingsTarget.app,
      );
    }
    return token;
  }

  @override
  Future<bool> openSettings(WorkerSettingsTarget target) {
    return target == WorkerSettingsTarget.locationServices
        ? Geolocator.openLocationSettings()
        : Geolocator.openAppSettings();
  }

  Future<WorkerAlertSettings> alertSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const WorkerAlertSettings(
        notificationPolicyAccess: false,
        channelCanBypassDnd: false,
        channelEnabled: true,
      );
    }
    final result =
        await _channel.invokeMapMethod<String, dynamic>('getAlertSettings') ??
            const {};
    return WorkerAlertSettings(
      notificationPolicyAccess: result['notificationPolicyAccess'] == true,
      channelCanBypassDnd: result['channelCanBypassDnd'] == true,
      channelEnabled: result['channelEnabled'] != false,
    );
  }

  Future<void> requestUrgentAlertAccess() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('requestUrgentAlertAccess');
    }
  }

  Future<void> openJobNotificationSettings() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('openJobNotificationSettings');
    }
  }

  @override
  Future<bool> respond({
    required String jobId,
    required String phone,
    required bool accept,
  }) async {
    await stopAlert();
    final response = await _post('/api/jobs/$jobId/respond', {
      'phone': phone,
      'decision': accept ? 'accepted' : 'rejected',
    });
    final result = response['response'];
    final accepted = result is Map && result['accepted'] == true;
    await _clearStoredJob();
    return accepted;
  }

  @override
  Future<Map<String, dynamic>> jobStatus({
    required String jobId,
    required String phone,
  }) async {
    final response = await _get('/api/jobs/$jobId/status?phone=$phone');
    final job = response['job'];
    return job is Map<String, dynamic> ? job : const {};
  }

  @override
  Future<WorkerJobRequest?> pendingJob({required String phone}) async {
    final query = Uri(queryParameters: {'phone': phone}).query;
    final response = await _get('/api/jobs/pending?$query');
    final job = response['job'];
    if (job is! Map<String, dynamic>) return null;
    final parsed = WorkerJobRequest.fromJson(job);
    if (parsed.id.isEmpty || parsed.isExpired) return null;
    await _storeJob(parsed);
    return parsed;
  }

  @override
  Future<WorkerDashboardSnapshot> dashboard({required String phone}) async {
    final preferences = await SharedPreferences.getInstance();
    final cacheKey = '$_dashboardCachePrefix$phone';
    try {
      final query = Uri(queryParameters: {'phone': phone}).query;
      final response = await _get('/api/workers/dashboard?$query');
      final raw = response['dashboard'];
      if (raw is! Map) throw StateError('Worker dashboard is unavailable');
      final snapshot = WorkerDashboardSnapshot.fromJson(
        Map<String, dynamic>.from(raw),
      );
      await preferences.setString(cacheKey, jsonEncode(snapshot.toJson()));
      return snapshot;
    } catch (_) {
      final cached = preferences.getString(cacheKey);
      if (cached == null) rethrow;
      return WorkerDashboardSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(cached) as Map),
      );
    }
  }

  @override
  Future<void> updateJobStatus({
    required String jobId,
    required String phone,
    required String status,
  }) async {
    await stopAlert();
    await _patch('/api/jobs/$jobId/status', {
      'phone': phone,
      'status': status,
    });
  }

  void _handleMessage(RemoteMessage message) {
    unawaited(_processMessage(message.data));
  }

  Future<void> _processMessage(Map<String, dynamic> data) async {
    if (data['type'] == 'job_cancelled') {
      final jobId = data['jobId']?.toString() ?? '';
      if (jobId.isEmpty) return;
      await _rememberCancelledJob(jobId);
      await _clearStoredJobIfMatching(jobId);
      if (_pendingJob?.id == jobId) _pendingJob = null;
      await stopAlert();
      _cancelledJobs.add(jobId);
      return;
    }
    if (data['type'] != 'job_offer') return;
    final job = WorkerJobRequest.fromJson(data);
    if (job.id.isEmpty || job.isExpired || await _wasJobCancelled(job.id)) {
      await stopAlert();
      return;
    }
    await _storeJob(job);
    final handler = _handler;
    if (handler == null) {
      _pendingJob = job;
    } else {
      final accepted = handler(job);
      if (!accepted) {
        await _clearStoredJob();
        await stopAlert();
        return;
      }
    }
    await startAlert();
  }

  Future<void> _storeJob(WorkerJobRequest job) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_pendingJobKey, jsonEncode(job.toJson()));
  }

  Future<WorkerJobRequest?> _readStoredJob() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_pendingJobKey);
    if (encoded == null) return null;
    try {
      return WorkerJobRequest.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
    } catch (_) {
      await preferences.remove(_pendingJobKey);
      return null;
    }
  }

  Future<void> _clearStoredJob() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_pendingJobKey);
  }

  static Future<void> _clearStoredJobIfMatching(String jobId) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_pendingJobKey);
    if (encoded == null) return;
    try {
      final stored = jsonDecode(encoded) as Map<String, dynamic>;
      final storedId = (stored['jobId'] ?? stored['id'])?.toString() ?? '';
      if (storedId == jobId) await preferences.remove(_pendingJobKey);
    } catch (_) {
      await preferences.remove(_pendingJobKey);
    }
  }

  static Future<bool> _wasJobCancelled(String jobId) async {
    final preferences = await SharedPreferences.getInstance();
    final cancelled = _readActiveCancellations(preferences);
    await preferences.setString(_cancelledJobsKey, jsonEncode(cancelled));
    return cancelled.containsKey(jobId);
  }

  static Future<void> _rememberCancelledJob(String jobId) async {
    final preferences = await SharedPreferences.getInstance();
    final cancelled = _readActiveCancellations(preferences);
    cancelled[jobId] = DateTime.now().toUtc().millisecondsSinceEpoch;
    await preferences.setString(_cancelledJobsKey, jsonEncode(cancelled));
  }

  static Map<String, int> _readActiveCancellations(
    SharedPreferences preferences,
  ) {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(_cancelledJobRetention)
        .millisecondsSinceEpoch;
    final encoded = preferences.getString(_cancelledJobsKey);
    if (encoded == null) return <String, int>{};
    try {
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries)
          if (entry.value is num && (entry.value as num).toInt() >= cutoff)
            entry.key: (entry.value as num).toInt(),
      };
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> startAlert() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('startJobAlert');
    }
  }

  @override
  Future<void> stopAlert() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('stopJobAlert');
    }
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    return _request('POST', path, body: body);
  }

  Future<Map<String, dynamic>> _patch(
      String path, Map<String, dynamic> body) async {
    return _request('PATCH', path, body: body);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    return _request('GET', path);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_configuredBaseUrl$path');
    const headers = {'Content-Type': 'application/json'};
    final encodedBody = body == null ? null : jsonEncode(body);
    final http.Response response;
    if (method == 'GET') {
      response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
    } else if (method == 'PATCH') {
      response = await _client
          .patch(uri, headers: headers, body: encodedBody)
          .timeout(const Duration(seconds: 20));
    } else {
      response = await _client
          .post(uri, headers: headers, body: encodedBody)
          .timeout(const Duration(seconds: 20));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(workerServiceFailureMessage(response));
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded;
  }
}
