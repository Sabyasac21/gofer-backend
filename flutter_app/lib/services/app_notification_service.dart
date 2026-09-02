import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/notification_models.dart';
import 'customer_api_service.dart';
import 'notification_api_service.dart';
import 'worker_dispatch_service.dart';

@pragma('vm:entry-point')
Future<void> workidaFirebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await WorkerDispatchService.persistBackgroundMessage(message.data);
}

class NotificationInboxController extends ChangeNotifier {
  NotificationInboxController(this._api);
  final NotificationApiService _api;

  List<AppNotification> notifications = const [];
  NotificationPreferences preferences = const NotificationPreferences();
  int unreadCount = 0;
  bool loading = false;
  String? error;

  Future<void> refresh() async {
    if (_api.credentials == null || loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final response = await _api.inbox();
      notifications = response.notifications;
      unreadCount = response.unreadCount;
      preferences = await _api.getPreferences();
    } catch (caught) {
      error = caught.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> open(AppNotification notification) async {
    if (!notification.isRead) {
      await _api.markRead(notification.id);
      notifications = notifications
          .map((item) => item.id == notification.id ? item.copyWith(isRead: true) : item)
          .toList(growable: false);
      unreadCount = unreadCount > 0 ? unreadCount - 1 : 0;
      notifyListeners();
    }
    AppNotificationService.instance.navigation.value = notification.data;
  }

  Future<void> markAllRead() async {
    await _api.markAllRead();
    notifications = notifications.map((item) => item.copyWith(isRead: true)).toList(growable: false);
    unreadCount = 0;
    notifyListeners();
  }

  Future<void> savePreferences(NotificationPreferences next) async {
    preferences = await _api.updatePreferences(next);
    notifyListeners();
  }

  void clear() {
    notifications = const [];
    unreadCount = 0;
    error = null;
    notifyListeners();
  }
}

class AppNotificationService {
  AppNotificationService._();

  static final instance = AppNotificationService._();
  static const _installationKey = 'workida_notification_installation_id';

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  final NotificationApiService _api = NotificationApiService();
  late final NotificationInboxController inbox = NotificationInboxController(_api);
  final ValueNotifier<Map<String, dynamic>?> navigation = ValueNotifier(null);
  StreamSubscription<String>? _tokenSubscription;
  NotificationApiCredentials? _credentials;
  String? _installationId;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('workida_notification'),
      iOS: DarwinInitializationSettings(),
    );
    await _local.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == null) return;
        try {
          navigation.value = Map<String, dynamic>.from(jsonDecode(response.payload!) as Map);
        } catch (_) {}
      },
    );
    await _createAndroidChannels();
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen((message) => _openData(message.data));
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _openData(initial.data);
    _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((_) => _registerCurrentToken());
  }

  Future<void> configureCustomer(CustomerApiService customerApi) async {
    if (kIsWeb) return;
    final credentials = await customerApi.notificationCredentials();
    _credentials = NotificationApiCredentials(
      flavor: 'customer',
      ownerHeader: 'X-Customer-Id',
      ownerValue: credentials.customerId,
      bearerToken: credentials.sessionToken,
    );
    _api.credentials = _credentials;
    await _requestPermission();
    await _registerCurrentToken();
    await inbox.refresh();
  }

  Future<void> configureWorker(String phone) async {
    if (kIsWeb || phone.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) return;
    _credentials = NotificationApiCredentials(
      flavor: 'worker',
      ownerHeader: 'X-Worker-Phone',
      ownerValue: phone,
      bearerToken: token,
    );
    _api.credentials = _credentials;
    await _requestPermission();
    await _registerCurrentToken();
    await inbox.refresh();
  }

  Future<void> unregister() async {
    final installationId = _installationId ?? await _getInstallationId();
    if (_api.credentials != null) {
      try {
        await _api.unregisterDevice(installationId);
      } catch (_) {}
    }
    _credentials = null;
    _api.credentials = null;
    inbox.clear();
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    navigation.dispose();
    inbox.dispose();
  }

  Future<void> _requestPermission() async {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: defaultTargetPlatform == TargetPlatform.iOS,
    );
  }

  Future<void> _registerCurrentToken() async {
    final credentials = _credentials;
    if (credentials == null) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
      if (apnsToken == null) return;
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    final package = await PackageInfo.fromPlatform();
    await _api.registerDevice(
      installationId: await _getInstallationId(),
      platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      fcmToken: token,
      appVersion: '${package.version}+${package.buildNumber}',
      locale: PlatformDispatcher.instance.locale.toLanguageTag(),
    );
  }

  Future<String> _getInstallationId() async {
    if (_installationId != null) return _installationId!;
    final preferences = await SharedPreferences.getInstance();
    _installationId = preferences.getString(_installationKey);
    if (_installationId == null) {
      _installationId = const Uuid().v4();
      await preferences.setString(_installationKey, _installationId!);
    }
    return _installationId!;
  }

  void _openData(Map<String, dynamic> data) {
    if (data.isEmpty) return;
    navigation.value = Map<String, dynamic>.from(data);
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    if (message.data['type'] == 'job_offer' || message.data['type'] == 'job_cancelled') return;
    final notification = message.notification;
    if (notification == null) return;
    final category = message.data['category']?.toString() ?? 'booking';
    final flavor = _credentials?.flavor ?? 'customer';
    final channelId = _channelId(flavor, category);
    await _local.show(
      message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          _channelName(channelId),
          importance: category == 'booking' ? Importance.high : Importance.defaultImportance,
          priority: category == 'booking' ? Priority.high : Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
      ),
      payload: jsonEncode(message.data),
    );
    await inbox.refresh();
  }

  String _channelId(String flavor, String category) {
    if (flavor == 'worker') {
      return switch (category) {
        'payment' => 'worker_payments',
        'account' => 'worker_account',
        'marketing' => 'worker_announcements',
        _ => 'worker_job_updates',
      };
    }
    return switch (category) {
      'payment' => 'customer_payments',
      'reminder' => 'customer_reminders',
      'marketing' => 'customer_offers_news',
      _ => 'customer_booking_updates',
    };
  }

  String _channelName(String id) => switch (id) {
        'worker_payments' => 'Earnings and payments',
        'worker_account' => 'Account and verification',
        'worker_announcements' => 'Worker announcements',
        'worker_job_updates' => 'Job updates',
        'customer_payments' => 'Payments and refunds',
        'customer_reminders' => 'Booking reminders',
        'customer_offers_news' => 'Offers and news',
        _ => 'Booking updates',
      };

  Future<void> _createAndroidChannels() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in const [
      AndroidNotificationChannel('worker_job_updates', 'Job updates', importance: Importance.high),
      AndroidNotificationChannel('worker_payments', 'Earnings and payments'),
      AndroidNotificationChannel('worker_account', 'Account and verification'),
      AndroidNotificationChannel('worker_announcements', 'Worker announcements', importance: Importance.low),
      AndroidNotificationChannel('customer_booking_updates', 'Booking updates', importance: Importance.high),
      AndroidNotificationChannel('customer_payments', 'Payments and refunds'),
      AndroidNotificationChannel('customer_reminders', 'Booking reminders', importance: Importance.high),
      AndroidNotificationChannel('customer_offers_news', 'Offers and news', importance: Importance.low),
    ]) {
      await android?.createNotificationChannel(channel);
    }
  }
}
