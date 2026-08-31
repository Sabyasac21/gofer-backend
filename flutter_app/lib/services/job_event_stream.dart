import 'dart:async';

import '../domain/marketplace_transaction.dart';

abstract interface class JobEventStream {
  Stream<MarketplaceTransaction> watch(String customerTaskId);
}

class PollingJobEventStream implements JobEventStream {
  PollingJobEventStream({
    required Future<MarketplaceTransaction> Function(String customerTaskId)
        load,
    this.interval = const Duration(seconds: 6),
  }) : _load = load;

  final Future<MarketplaceTransaction> Function(String customerTaskId) _load;
  final Duration interval;

  @override
  Stream<MarketplaceTransaction> watch(String customerTaskId) {
    late StreamController<MarketplaceTransaction> controller;
    Timer? timer;
    var requestInFlight = false;
    String? lastVersion;

    Future<void> refresh() async {
      if (requestInFlight || controller.isClosed) return;
      requestInFlight = true;
      try {
        final transaction = await _load(customerTaskId);
        final version = [
          transaction.status,
          transaction.currentLabour,
          transaction.requirements.length,
          transaction.timeSegments.length,
          transaction.additionalWork.length,
          transaction.events.lastOrNull?.id,
          transaction.payment?.status.name,
          transaction.ratingSubmitted,
        ].join(':');
        if (version != lastVersion && !controller.isClosed) {
          lastVersion = version;
          controller.add(transaction);
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        requestInFlight = false;
      }
    }

    controller = StreamController<MarketplaceTransaction>(
      onListen: () {
        unawaited(refresh());
        timer = Timer.periodic(interval, (_) => unawaited(refresh()));
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
