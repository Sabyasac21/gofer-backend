import '../models/taskr_models.dart';

class BookingSchedulePolicy {
  const BookingSchedulePolicy._();

  static const maximumAdvanceDays = 3;

  static DateTime startOfDay(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime firstLaterDate(DateTime now) =>
      startOfDay(now).add(const Duration(days: 1));

  static DateTime lastLaterDate(DateTime now) => startOfDay(now).add(
        const Duration(days: maximumAdvanceDays),
      );

  static DateTime nextQuarterHour(DateTime now) {
    final withoutSeconds = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    );
    final remainder = withoutSeconds.minute % 15;
    final minutes = remainder == 0 && now.second == 0 && now.millisecond == 0
        ? 15
        : 15 - remainder;
    return withoutSeconds.add(Duration(minutes: minutes));
  }

  static bool isValid({
    required TaskUrgency urgency,
    required DateTime? scheduledAt,
    required DateTime now,
  }) {
    if (urgency == TaskUrgency.now) return scheduledAt == null;
    if (scheduledAt == null || !scheduledAt.isAfter(now)) return false;

    final selectedDay = startOfDay(scheduledAt);
    final today = startOfDay(now);
    if (urgency == TaskUrgency.today) return selectedDay == today;

    return !selectedDay.isBefore(firstLaterDate(now)) &&
        !selectedDay.isAfter(lastLaterDate(now));
  }

  static String timeUntilLabel(DateTime scheduledAt, DateTime now) {
    final remaining = scheduledAt.difference(now);
    if (remaining <= Duration.zero) return 'Service time has arrived';

    final totalMinutes = remaining.inMinutes +
        (remaining.inSeconds % Duration.secondsPerMinute == 0 ? 0 : 1);
    final days = totalMinutes ~/ Duration.minutesPerDay;
    final hours =
        (totalMinutes % Duration.minutesPerDay) ~/ Duration.minutesPerHour;
    final minutes = totalMinutes % Duration.minutesPerHour;

    final parts = <String>[];
    if (days > 0) parts.add('$days ${days == 1 ? 'day' : 'days'}');
    if (hours > 0) parts.add('$hours hr');
    if (minutes > 0) parts.add('$minutes min');

    return 'Service starts in ${parts.join(' ')}';
  }
}
