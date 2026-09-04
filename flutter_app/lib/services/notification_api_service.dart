import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/notification_models.dart';

class NotificationApiException implements Exception {
  const NotificationApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NotificationApiCredentials {
  const NotificationApiCredentials({
    required this.flavor,
    required this.ownerHeader,
    required this.ownerValue,
    required this.bearerToken,
  });
  final String flavor;
  final String ownerHeader;
  final String ownerValue;
  final String bearerToken;
}

class NotificationInboxResponse {
  const NotificationInboxResponse(this.notifications, this.unreadCount);
  final List<AppNotification> notifications;
  final int unreadCount;
}

class NotificationApiService {
  NotificationApiService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? _resolvedBaseUrl;

  static const _configuredBaseUrl = String.fromEnvironment(
    'GOFER_NOTIFICATION_API_BASE_URL',
    defaultValue: '',
  );

  static String get _resolvedBaseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    // No notification service is configured for this build. In debug, fall back
    // to a local dev instance; in release, stay disabled rather than blocking
    // every notification call on an unreachable host for the full socket
    // timeout (~20s on Android).
    if (kReleaseMode) return '';
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3006';
    }
    return 'http://localhost:3006';
  }

  final http.Client _client;
  final String _baseUrl;
  NotificationApiCredentials? credentials;

  /// Whether a notification backend is actually reachable for this build.
  /// Callers skip notification setup/teardown entirely when this is false.
  bool get isConfigured => _baseUrl.isNotEmpty;

  Map<String, String> get _headers {
    final current = credentials;
    if (current == null) throw const NotificationApiException('Notification session is not configured.');
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${current.bearerToken}',
      'X-App-Flavor': current.flavor,
      current.ownerHeader: current.ownerValue,
    };
  }

  Future<void> registerDevice({
    required String installationId,
    required String platform,
    required String fcmToken,
    required String appVersion,
    required String locale,
  }) async {
    await _request('POST', '/api/notifications/devices', body: {
      'installationId': installationId,
      'appFlavor': credentials!.flavor,
      'platform': platform,
      'fcmToken': fcmToken,
      'appVersion': appVersion,
      'locale': locale,
    });
  }

  Future<void> unregisterDevice(String installationId) =>
      _request('DELETE', '/api/notifications/devices/$installationId');

  Future<NotificationInboxResponse> inbox() async {
    final json = await _request('GET', '/api/notifications?limit=100');
    final rows = json['notifications'] as List? ?? const [];
    return NotificationInboxResponse(
      rows.whereType<Map>().map((row) => AppNotification.fromJson(Map<String, dynamic>.from(row))).toList(),
      (json['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> markRead(String id) => _request('PATCH', '/api/notifications/$id/read');
  Future<void> markAllRead() => _request('POST', '/api/notifications/read-all');

  Future<NotificationPreferences> getPreferences() async {
    final json = await _request('GET', '/api/notifications/preferences');
    return NotificationPreferences.fromJson(Map<String, dynamic>.from(json['preferences'] as Map));
  }

  Future<NotificationPreferences> updatePreferences(NotificationPreferences preferences) async {
    final json = await _request('PUT', '/api/notifications/preferences', body: preferences.toJson());
    return NotificationPreferences.fromJson(Map<String, dynamic>.from(json['preferences'] as Map));
  }

  Future<Map<String, dynamic>> _request(String method, String path, {Map<String, dynamic>? body}) async {
    if (_baseUrl.isEmpty) {
      throw const NotificationApiException(
        'Notification service is not configured for this build.',
      );
    }
    final uri = Uri.parse('$_baseUrl$path');
    final pending = switch (method) {
      'GET' => _client.get(uri, headers: _headers),
      'POST' => _client.post(uri, headers: _headers, body: jsonEncode(body ?? const {})),
      'PUT' => _client.put(uri, headers: _headers, body: jsonEncode(body ?? const {})),
      'PATCH' => _client.patch(uri, headers: _headers, body: jsonEncode(body ?? const {})),
      'DELETE' => _client.delete(uri, headers: _headers),
      _ => throw UnsupportedError(method),
    };
    final response = await pending.timeout(const Duration(seconds: 8));
    if (response.statusCode == 204) return const {};
    Map<String, dynamic> decoded = const {};
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {}
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NotificationApiException(decoded['message'] as String? ?? 'Notification request failed (HTTP ${response.statusCode}).');
    }
    return decoded;
  }
}
