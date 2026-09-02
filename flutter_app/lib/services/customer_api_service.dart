import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/sample_data.dart';
import '../domain/job_lifecycle.dart';
import '../domain/household_assistance.dart';
import '../domain/marketplace_transaction.dart';
import '../domain/pricing_engine.dart';
import '../models/taskr_models.dart';

class CustomerApiException implements Exception {
  const CustomerApiException(this.message,
      {this.statusCode, this.code, this.cause});
  final String message;
  final int? statusCode;
  final String? code;
  final Object? cause;
  @override
  String toString() => message;
}

class CustomerPricingQuote {
  const CustomerPricingQuote({
    required this.config,
    required this.estimate,
  });

  final ServicePricingConfig config;
  final PricingEstimate estimate;
}

class CustomerNotificationCredentials {
  const CustomerNotificationCredentials({
    required this.customerId,
    required this.sessionToken,
  });

  final String customerId;
  final String sessionToken;
}

class CustomerIdentity {
  const CustomerIdentity({
    required this.id,
    required this.name,
    this.phone,
    required this.phoneVerified,
  });

  final String id;
  final String name;
  final String? phone;
  final bool phoneVerified;
}

class CustomerDispatchStatus {
  const CustomerDispatchStatus({
    required this.status,
    required this.offerCount,
    this.worker,
    this.jobId,
    this.createdAt,
    this.expiresAt,
    this.acceptedAt,
    this.arrivedAt,
    this.startedAt,
    this.completionRequestedAt,
    this.completedAt,
  });

  final String status;
  final int offerCount;
  final WorkerProfile? worker;
  final String? jobId;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? acceptedAt;
  final DateTime? arrivedAt;
  final DateTime? startedAt;
  final DateTime? completionRequestedAt;
  final DateTime? completedAt;

  JobStatus get lifecycleStatus => switch (status) {
        'offered' => JobStatus.searching,
        'expired' => JobStatus.noWorkerAvailable,
        'accepted' => JobStatus.workerAccepted,
        'arrived' => JobStatus.arrived,
        'started' => JobStatus.working,
        'completion_requested' => JobStatus.completionRequested,
        'completed' => JobStatus.completed,
        'cancelled' => JobStatus.cancelled,
        _ => JobStatus.requested,
      };

  List<JobTimelineEvent> get timeline {
    final events = <JobTimelineEvent>[];
    void add(
      DateTime? at,
      JobEventType type,
      JobStatus eventStatus,
      String title,
    ) {
      if (at == null) return;
      events.add(JobTimelineEvent(
        id: '${jobId ?? 'job'}-${type.name}',
        type: type,
        status: eventStatus,
        occurredAt: at,
        title: title,
      ));
    }

    add(createdAt, JobEventType.jobCreated, JobStatus.searching, 'Job created');
    add(acceptedAt, JobEventType.workerAccepted, JobStatus.workerAccepted,
        'Worker accepted');
    add(arrivedAt, JobEventType.workerArrived, JobStatus.arrived,
        'Worker arrived');
    add(startedAt, JobEventType.jobStarted, JobStatus.working, 'Work started');
    add(
      completionRequestedAt,
      JobEventType.jobCompletionRequested,
      JobStatus.completionRequested,
      'Completion requested',
    );
    add(completedAt, JobEventType.customerCompleted, JobStatus.completed,
        'Completion confirmed');
    events.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    return events;
  }
}

class CustomerApiService {
  CustomerApiService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? _resolvedBaseUrl,
        _workerBaseUrl = _resolvedWorkerBaseUrl;

  static const _configuredBaseUrl = String.fromEnvironment(
    'GOFER_TASK_API_BASE_URL',
    defaultValue: 'https://gofer-backend.onrender.com',
  );
  static const _configuredWorkerBaseUrl = String.fromEnvironment(
    'GOFER_WORKER_API_BASE_URL',
    // Worker phones register their FCM token with the deployed worker service.
    // Use that same service for dispatch even when the customer UI runs locally,
    // otherwise the job is written to a different presence/token database.
    defaultValue: 'https://gofer-backend.onrender.com',
  );
  static const _customerIdKey = 'gofer_customer_id';
  static const _customerSessionTokenKey = 'gofer_customer_session_token';
  static const _customerNameKey = 'gofer_customer_name';
  static const _customerPhoneKey = 'gofer_customer_phone';
  static const _customerPhoneVerifiedKey = 'gofer_customer_phone_verified';

  static String get _resolvedBaseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3002';
    }
    return 'http://localhost:3002';
  }

  static String get _resolvedWorkerBaseUrl {
    return _configuredWorkerBaseUrl;
  }

  final http.Client _client;
  static const _secureStorage = FlutterSecureStorage();
  final String _baseUrl;
  final String _workerBaseUrl;
  String? _customerId;
  String? _customerSessionToken;
  CustomerIdentity? _identity;

  CustomerIdentity? get customerIdentity => _identity;
  bool get isPhoneVerified => _identity?.phoneVerified ?? false;

  Future<String> ensureCustomerSession({String name = 'Powel'}) async {
    // Several screens own lightweight API clients. Phone verification can
    // rotate the persisted session while a booking client is already alive,
    // so always rehydrate the credentials before an authenticated request.
    // This avoids sending the pre-verification anonymous token.
    final preferences = await SharedPreferences.getInstance();
    final savedId = preferences.getString(_customerIdKey);
    final legacyToken = preferences.getString(_customerSessionTokenKey);
    final savedToken =
        await _secureStorage.read(key: _customerSessionTokenKey) ?? legacyToken;
    final body = await _request(
      'POST',
      '/api/customers/session',
      body: {
        'customerId': savedId,
        'sessionToken': savedToken,
        'name': name,
      },
    );
    final customer = body['customer'];
    final sessionToken = body['sessionToken'];
    if (customer is! Map ||
        customer['id'] is! String ||
        sessionToken is! String) {
      throw const CustomerApiException('Invalid customer session response.');
    }
    await _saveSession(
        preferences, customer.cast<String, dynamic>(), sessionToken);
    if (legacyToken != null) {
      await preferences.remove(_customerSessionTokenKey);
    }
    return _customerId!;
  }

  Future<CustomerIdentity> loadCustomerIdentity() async {
    await ensureCustomerSession();
    return _identity!;
  }

  Future<CustomerIdentity> verifyPhone({
    required String firebaseIdToken,
    String name = 'Workida customer',
  }) async {
    await ensureCustomerSession(name: name);
    final body = await _request(
      'POST',
      '/api/customers/verify-phone',
      body: {
        'customerId': _customerId,
        'sessionToken': _customerSessionToken,
        'idToken': firebaseIdToken,
        'name': name,
      },
    );
    final customer = body['customer'];
    final sessionToken = body['sessionToken'];
    if (customer is! Map || sessionToken is! String) {
      throw const CustomerApiException('Invalid phone verification response.');
    }
    await _saveSession(
      await SharedPreferences.getInstance(),
      customer.cast<String, dynamic>(),
      sessionToken,
    );
    return _identity!;
  }

  Future<void> clearCustomerSession() async {
    _customerId = null;
    _customerSessionToken = null;
    _identity = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_customerIdKey);
    await preferences.remove(_customerNameKey);
    await preferences.remove(_customerPhoneKey);
    await preferences.remove(_customerPhoneVerifiedKey);
    await preferences.remove(_customerSessionTokenKey);
    await _secureStorage.delete(key: _customerSessionTokenKey);
  }

  Future<void> _saveSession(
    SharedPreferences preferences,
    Map<String, dynamic> customer,
    String sessionToken,
  ) async {
    final id = customer['id'];
    if (id is! String) {
      throw const CustomerApiException('Invalid customer identity.');
    }
    final identity = CustomerIdentity(
      id: id,
      name: customer['name'] as String? ?? 'Workida customer',
      phone: customer['phone'] as String?,
      phoneVerified: customer['phoneVerified'] == true,
    );
    _customerId = identity.id;
    _customerSessionToken = sessionToken;
    _identity = identity;
    await preferences.setString(_customerIdKey, identity.id);
    await preferences.setString(_customerNameKey, identity.name);
    if (identity.phone != null) {
      await preferences.setString(_customerPhoneKey, identity.phone!);
    }
    await preferences.setBool(
        _customerPhoneVerifiedKey, identity.phoneVerified);
    await _secureStorage.write(
        key: _customerSessionTokenKey, value: sessionToken);
  }

  Future<CustomerNotificationCredentials> notificationCredentials() async {
    final customerId = await ensureCustomerSession();
    return CustomerNotificationCredentials(
      customerId: customerId,
      sessionToken: _customerSessionToken!,
    );
  }

  Future<List<WorkerProfile>> nearbyWorkers({
    required double latitude,
    required double longitude,
    double radiusKm = 10,
  }) async {
    final body = await _request(
      'GET',
      '/api/workers/verified',
      baseUrl: _workerBaseUrl,
    );
    final workers = body['workers'];
    if (workers is! List) return const [];
    return workers
        .whereType<Map<String, dynamic>>()
        .map(WorkerProfile.fromJson)
        .toList(growable: false);
  }

  Future<CustomerPricingQuote> pricingQuote({
    required String serviceId,
    required String serviceType,
    String? capabilityKey,
    String? category,
    String? variantId,
    required String city,
    required int quantity,
    int? estimatedDurationMinutes,
  }) async {
    final body = await _request(
      'POST',
      '/api/pricing/quotes',
      body: {
        'serviceId': serviceId,
        'serviceType': serviceType,
        'capabilityKey': capabilityKey,
        'category': category,
        'variantId': variantId,
        'city': city,
        'quantity': quantity,
        if (estimatedDurationMinutes != null)
          'estimatedDurationMinutes': estimatedDurationMinutes,
      },
    );
    final quote = body['quote'];
    if (quote is! Map<String, dynamic>) {
      throw const CustomerApiException('Invalid pricing quote response.');
    }
    return CustomerPricingQuote(
      config: ServicePricingConfig.fromJson(
        quote['pricingConfig'] as Map<String, dynamic>,
      ),
      estimate: PricingEstimate.fromJson(
        quote['estimate'] as Map<String, dynamic>,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> pricingCatalogServices() async {
    final body = await _request('GET', '/api/pricing/catalog');
    final priceBook = body['priceBook'];
    if (priceBook is! Map<String, dynamic> || priceBook['services'] is! List) {
      throw const CustomerApiException('Invalid service catalogue response.');
    }
    return (priceBook['services'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

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
    final customerId = await ensureCustomerSession();
    final body = await _request(
      'POST',
      '/api/tasks',
      attempts: idempotencyKey == null ? 1 : 2,
      body: {
        'customerId': customerId,
        'category': category.id,
        'title': title,
        'description': description,
        'address': location,
        'latitude': latitude,
        'longitude': longitude,
        'urgency': urgency.name,
        'scheduledAt': scheduledAt?.toUtc().toIso8601String(),
        'budget': budget,
        'serviceType': serviceType,
        'helperCategory': helperCategory,
        'professionalCategory': professionalCategory,
        'serviceId': serviceId,
        'capabilityKey': capabilityKey,
        'eligibleWorkerCategories': eligibleWorkerCategories,
        'estimatedMinPrice': estimatedMinPrice,
        'estimatedMaxPrice': estimatedMaxPrice,
        'expectedDuration': expectedDuration,
        'estimatedDurationMinutes': estimatedDurationMinutes,
        'pricingSnapshot': pricingSnapshot,
        'notes': notes,
        'workCondition': workCondition,
        'quoteId': quoteId,
        'idempotencyKey': idempotencyKey,
      },
    );
    final task = TaskRequest.fromJson(
      body['task'] as Map<String, dynamic>,
      categories: serviceCategoriesById,
    );
    if (serviceType != null) await ensureDispatch(task);
    return task;
  }

  Future<HouseholdBookingQuote> createHouseholdQuote({
    required Map<String, String> selectedWorkloads,
    required int durationHours,
  }) async {
    final customerId = await ensureCustomerSession();
    final body = await _request(
      'POST',
      '/api/household-help/quotes',
      body: {
        'customerId': customerId,
        'durationHours': durationHours,
        'chores': [
          for (final entry in selectedWorkloads.entries)
            {'id': entry.key, 'workloadId': entry.value},
        ],
      },
    );
    return HouseholdBookingQuote.fromJson(
      body['quote'] as Map<String, dynamic>,
    );
  }

  Future<void> ensureDispatch(TaskRequest task) async {
    final serviceType = task.serviceType;
    if (serviceType == null) return;
    final customerId = await ensureCustomerSession();
    await _request(
      'POST',
      '/api/jobs/dispatch',
      baseUrl: _workerBaseUrl,
      body: {
        'customerTaskId': task.id,
        'customerId': customerId,
        'serviceType': serviceType,
        // Broad category is authoritative for pricing/matching; title and
        // serviceId retain the exact customer-selected service.
        'category': task.category.name,
        'serviceId': task.serviceId,
        'capabilityKey': task.capabilityKey,
        'eligibleWorkerCategories': task.eligibleWorkerCategories,
        'title': task.title,
        'notes': task.notes ?? task.description,
        'address': task.location,
        'latitude': task.latitude,
        'longitude': task.longitude,
        'budget': task.budget,
        'durationLabel': task.expectedDuration,
        'estimatedDurationMinutes': task.estimatedDurationMinutes,
        'scheduledAt': task.scheduledAt?.toUtc().toIso8601String(),
        'pricingSnapshot': task.pricingSnapshot,
        'scope': task.description
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(),
      },
    );
  }

  Future<List<TaskRequest>> tasks() async {
    final customerId = await ensureCustomerSession();
    final query = Uri(queryParameters: {'customerId': customerId}).query;
    final body = await _request('GET', '/api/tasks?$query');
    final tasks = body['tasks'];
    if (tasks is! List) return const [];
    return tasks
        .whereType<Map<String, dynamic>>()
        .map((json) =>
            TaskRequest.fromJson(json, categories: serviceCategoriesById))
        .toList(growable: false);
  }

  Future<TaskRequest> updateTaskStatus(
    TaskRequest task,
    TaskStatus status, {
    String? workerId,
  }) async {
    final customerId = await ensureCustomerSession();
    final body = await _request('PATCH', '/api/tasks/${task.id}/status', body: {
      'customerId': customerId,
      'status': status.name,
      'workerId': workerId,
    });
    return TaskRequest.fromJson(
      body['task'] as Map<String, dynamic>,
      categories: serviceCategoriesById,
    );
  }

  Future<CustomerDispatchStatus> dispatchStatus(String customerTaskId) async {
    final cacheBuster = DateTime.now().millisecondsSinceEpoch;
    final body = await _request(
      'GET',
      '/api/jobs/customer-task/$customerTaskId?t=$cacheBuster',
      baseUrl: _workerBaseUrl,
    );
    final dispatch = body['dispatch'] as Map<String, dynamic>;
    final workerJson = dispatch['worker'];
    return CustomerDispatchStatus(
      jobId: dispatch['id'] as String?,
      status: dispatch['status'] as String? ?? 'offered',
      offerCount: (dispatch['offerCount'] as num?)?.toInt() ?? 0,
      createdAt: _dateTime(dispatch['createdAt']),
      expiresAt: _dateTime(dispatch['expiresAt']),
      acceptedAt: _dateTime(dispatch['acceptedAt']),
      arrivedAt: _dateTime(dispatch['arrivedAt']),
      startedAt: _dateTime(dispatch['startedAt']),
      completionRequestedAt: _dateTime(dispatch['completionRequestedAt']),
      completedAt: _dateTime(dispatch['completedAt']),
      worker: workerJson is Map<String, dynamic>
          ? WorkerProfile.fromJson(workerJson)
          : null,
    );
  }

  static DateTime? _dateTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  Future<void> updateDispatchStatus(
    String customerTaskId,
    String status,
  ) async {
    await _request(
      'PATCH',
      '/api/jobs/customer-task/$customerTaskId/status',
      baseUrl: _workerBaseUrl,
      body: {'status': status},
    );
  }

  Future<MarketplaceTransaction> marketplaceTransaction(
    String customerTaskId,
  ) async {
    await ensureCustomerSession();
    final body = await _request(
      'GET',
      '/api/marketplace/customer-tasks/$customerTaskId',
      baseUrl: _workerBaseUrl,
    );
    return MarketplaceTransaction.fromJson(
      Map<String, dynamic>.from(body['transaction'] as Map),
    );
  }

  Future<void> updateRequirement({
    required String customerTaskId,
    required String requirementId,
    required RequirementStatus status,
    required String idempotencyKey,
  }) async {
    await ensureCustomerSession();
    await _request(
      'PATCH',
      '/api/marketplace/customer-tasks/$customerTaskId/requirements/$requirementId',
      baseUrl: _workerBaseUrl,
      body: {
        'status': status.name,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<void> decideMarketplaceAdditionalWork({
    required String customerTaskId,
    required String requestId,
    required AdditionalWorkStatus decision,
    required String idempotencyKey,
  }) async {
    await ensureCustomerSession();
    await _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/additional-work/$requestId/decision',
      baseUrl: _workerBaseUrl,
      body: {
        'decision': decision.name,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<void> reportRemainingWork({
    required String customerTaskId,
    required String description,
    required String idempotencyKey,
    List<String> evidence = const [],
  }) async {
    await ensureCustomerSession();
    await _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/remaining-work',
      baseUrl: _workerBaseUrl,
      body: {
        'description': description,
        'evidence': evidence,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<void> createMarketplaceCase({
    required String customerTaskId,
    required String caseType,
    required String category,
    required String description,
    required String idempotencyKey,
    List<String> evidence = const [],
  }) async {
    await ensureCustomerSession();
    await _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/$caseType',
      baseUrl: _workerBaseUrl,
      body: {
        'category': category,
        'description': description,
        'evidence': evidence,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<void> confirmMarketplaceCompletion({
    required String customerTaskId,
    required String idempotencyKey,
  }) async {
    await ensureCustomerSession();
    await _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/complete',
      baseUrl: _workerBaseUrl,
      body: {'idempotencyKey': idempotencyKey},
    );
  }

  Future<Map<String, dynamic>> createPaymentAttempt({
    required String customerTaskId,
    required String idempotencyKey,
  }) async {
    await ensureCustomerSession();
    return _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/payment-attempts',
      baseUrl: _workerBaseUrl,
      body: {'idempotencyKey': idempotencyKey},
    );
  }

  Future<void> submitMarketplaceRating({
    required String customerTaskId,
    required int quality,
    required int professionalism,
    required int punctuality,
    required int communication,
    required String idempotencyKey,
    String? comment,
  }) async {
    await ensureCustomerSession();
    await _request(
      'POST',
      '/api/marketplace/customer-tasks/$customerTaskId/rating',
      baseUrl: _workerBaseUrl,
      body: {
        'quality': quality,
        'professionalism': professionalism,
        'punctuality': punctuality,
        'communication': communication,
        'comment': comment,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? baseUrl,
    int attempts = 1,
  }) async {
    final uri = Uri.parse('${baseUrl ?? _baseUrl}$path');
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_customerSessionToken != null) {
      headers['Authorization'] = 'Bearer $_customerSessionToken';
    }
    if (_customerId != null) headers['X-Customer-Id'] = _customerId!;
    http.Response? response;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        response = switch (method) {
          'GET' => await _client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15)),
          'POST' => await _client
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 15)),
          'PATCH' => await _client
              .patch(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 15)),
          _ => throw UnsupportedError('Unsupported HTTP method $method'),
        };
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (response == null) {
      throw CustomerApiException(
        'Cannot reach the Workida service. Check your connection and try again.',
        cause: lastError,
      );
    }
    Map<String, dynamic> decoded = const {};
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CustomerApiException(
        decoded['message'] as String? ?? 'Gofer service request failed.',
        statusCode: response.statusCode,
        code: decoded['code'] as String?,
      );
    }
    return decoded;
  }
}
