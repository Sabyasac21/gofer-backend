class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.category,
    required this.title,
    required this.body,
    required this.data,
    required this.isRead,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String category;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final bool isRead;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        type: json['type'] as String? ?? 'notification',
        category: json['category'] as String? ?? 'account',
        title: json['title'] as String? ?? 'Workida',
        body: json['body'] as String? ?? '',
        data: Map<String, dynamic>.from(json['data'] as Map? ?? const {}),
        isRead: json['isRead'] == true,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      );

  AppNotification copyWith({bool? isRead}) => AppNotification(
        id: id,
        type: type,
        category: category,
        title: title,
        body: body,
        data: data,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
      );
}

class NotificationPreferences {
  const NotificationPreferences({
    this.bookingUpdates = true,
    this.payments = true,
    this.accountUpdates = true,
    this.reminders = true,
    this.marketing = false,
    this.timezone = 'Asia/Kolkata',
  });

  final bool bookingUpdates;
  final bool payments;
  final bool accountUpdates;
  final bool reminders;
  final bool marketing;
  final String timezone;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) => NotificationPreferences(
        bookingUpdates: json['bookingUpdates'] != false,
        payments: json['payments'] != false,
        accountUpdates: json['accountUpdates'] != false,
        reminders: json['reminders'] != false,
        marketing: json['marketing'] == true,
        timezone: json['timezone'] as String? ?? 'Asia/Kolkata',
      );

  Map<String, dynamic> toJson() => {
        'bookingUpdates': bookingUpdates,
        'payments': payments,
        'accountUpdates': accountUpdates,
        'reminders': reminders,
        'marketing': marketing,
        'timezone': timezone,
      };

  NotificationPreferences copyWith({
    bool? bookingUpdates,
    bool? payments,
    bool? accountUpdates,
    bool? reminders,
    bool? marketing,
  }) => NotificationPreferences(
        bookingUpdates: bookingUpdates ?? this.bookingUpdates,
        payments: payments ?? this.payments,
        accountUpdates: accountUpdates ?? this.accountUpdates,
        reminders: reminders ?? this.reminders,
        marketing: marketing ?? this.marketing,
        timezone: timezone,
      );
}
