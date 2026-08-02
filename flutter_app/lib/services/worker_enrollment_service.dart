import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/worker_models.dart';

class WorkerEnrollmentException implements Exception {
  const WorkerEnrollmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WorkerEnrollmentStatus {
  const WorkerEnrollmentStatus({
    required this.exists,
    this.id = '',
    this.fullName = '',
    this.reviewStatus = '',
    this.workerStatus = '',
    this.kycStatus = '',
    this.submittedAt,
  });

  final bool exists;
  final String id;
  final String fullName;
  final String reviewStatus;
  final String workerStatus;
  final String kycStatus;
  final DateTime? submittedAt;

  factory WorkerEnrollmentStatus.fromJson(Map<String, dynamic> json) {
    final enrollment = json['enrollment'];
    if (enrollment is! Map<String, dynamic>) {
      return const WorkerEnrollmentStatus(exists: false);
    }

    return WorkerEnrollmentStatus(
      exists: json['exists'] == true,
      id: enrollment['id'] as String? ?? '',
      fullName: enrollment['fullName'] as String? ?? '',
      reviewStatus: enrollment['reviewStatus'] as String? ?? '',
      workerStatus: enrollment['workerStatus'] as String? ?? '',
      kycStatus: enrollment['kycStatus'] as String? ?? '',
      submittedAt:
          DateTime.tryParse(enrollment['submittedAt'] as String? ?? ''),
    );
  }
}

class WorkerEnrollmentService {
  WorkerEnrollmentService({
    http.Client? client,
    String? baseUrl,
    Duration retryDelay = const Duration(milliseconds: 800),
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? _resolvedBaseUrl,
        _retryDelay = retryDelay;

  static const _configuredBaseUrl = String.fromEnvironment(
    'GOFER_WORKER_API_BASE_URL',
    defaultValue: 'https://gofer-backend.onrender.com',
  );

  static String get _resolvedBaseUrl {
    return _configuredBaseUrl;
  }

  final http.Client _client;
  final String _baseUrl;
  final Duration _retryDelay;

  Future<WorkerEnrollmentStatus> statusForPhone(String phone) async {
    Object? lastError;
    http.Response? lastResponse;
    final uri = Uri.parse('$_baseUrl/api/workers/enrollments/status').replace(
      queryParameters: {'phone': phone},
    );

    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final response = await _client.get(uri).timeout(
              const Duration(seconds: 20),
            );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic>) {
            return WorkerEnrollmentStatus.fromJson(body);
          }
          throw const WorkerEnrollmentException(
            'Gofer backend returned an invalid enrollment response.',
          );
        }

        if (!_isRetryableStatus(response.statusCode)) {
          throw WorkerEnrollmentException(_errorMessage(response));
        }
        lastResponse = response;
      } catch (error) {
        if (error is WorkerEnrollmentException) rethrow;
        lastError = error;
      }

      if (attempt < 2) {
        await Future<void>.delayed(_retryDelay * (attempt + 1));
      }
    }

    if (lastResponse != null) {
      throw WorkerEnrollmentException(_errorMessage(lastResponse));
    }
    throw WorkerEnrollmentException(
      _networkErrorMessage(lastError),
    );
  }

  Future<void> submit(WorkerApplication application) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/api/workers/enrollments'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(_toJson(application)),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    final message = _errorMessage(response);
    throw WorkerEnrollmentException(message);
  }

  Map<String, dynamic> _toJson(WorkerApplication application) {
    return {
      'phone': application.phone,
      'language': application.language,
      'fullName': application.fullName,
      'age': int.tryParse(application.age),
      'city': application.city,
      'workArea': application.workArea,
      'emergencyContact': application.emergencyContact,
      'experience': application.experience,
      'travelRadiusKm': application.travelRadiusKm,
      'enrollmentTypes':
          application.enrollmentTypes.map((type) => type.name).toList(),
      'professionalCategories': application.professionalCategories.toList(),
      'idType': application.idType?.name,
      'documents': application.documents.values
          .map(
            (document) => {
              'type': document.type.name,
              'path': document.path,
              'fileName': document.fileName,
              'contentType': document.contentType,
              'contentBase64': document.contentBase64,
              'validationChecks': document.validationChecks
                  .map(
                    (check) => {
                      'label': check.label,
                      'passed': check.passed,
                      'message': check.message,
                    },
                  )
                  .toList(),
              'extractedFields': document.extractedFields,
            },
          )
          .toList(),
      'consentAccepted': application.consentAccepted,
      'consentVersion': application.consentVersion,
      'consentAcceptedAt': application.consentAcceptedAt?.toIso8601String(),
    };
  }

  String _errorMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final message = body['message'];
        if (message is String && message.isNotEmpty) return message;
        final error = body['error'];
        if (error is Map<String, dynamic>) {
          final nestedMessage = error['message'];
          if (nestedMessage is String && nestedMessage.isNotEmpty) {
            return nestedMessage;
          }
        }
      }
    } catch (_) {
      // Fall through to the generic status message.
    }
    return 'Could not submit worker enrollment. Please try again.';
  }

  bool _isRetryableStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  String _networkErrorMessage(Object? error) {
    if (error is TimeoutException) {
      return 'Gofer backend took too long to respond. Please try again.';
    }
    return 'Could not reach Gofer backend. Please check internet and try again.';
  }
}
