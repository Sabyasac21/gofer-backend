import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/booking_schedule.dart';

class BookingCountdownLabel extends StatefulWidget {
  const BookingCountdownLabel({
    super.key,
    required this.scheduledAt,
    this.style,
  });

  final DateTime scheduledAt;
  final TextStyle? style;

  @override
  State<BookingCountdownLabel> createState() => _BookingCountdownLabelState();
}

class _BookingCountdownLabelState extends State<BookingCountdownLabel>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant BookingCountdownLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheduledAt != widget.scheduledAt) _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  void _refresh() {
    if (mounted) setState(() => _now = DateTime.now());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        BookingSchedulePolicy.timeUntilLabel(widget.scheduledAt, _now),
        key: const ValueKey('booking-countdown-label'),
        style: widget.style ??
            const TextStyle(
              color: Color(0xFF08786F),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
      );
}
