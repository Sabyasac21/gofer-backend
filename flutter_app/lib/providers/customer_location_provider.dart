import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/customer_location_service.dart';

enum CustomerLocationStatus { initial, fetching, ready, needsSelection }

class CustomerLocationState {
  const CustomerLocationState({
    this.status = CustomerLocationStatus.initial,
    this.location = ServiceLocation.fallback,
    this.message,
  });

  final CustomerLocationStatus status;
  final ServiceLocation location;
  final String? message;
}

final customerLocationProvider =
    StateNotifierProvider<CustomerLocationController, CustomerLocationState>(
  (ref) => CustomerLocationController(),
);

class CustomerLocationController extends StateNotifier<CustomerLocationState> {
  CustomerLocationController({CustomerLocationService? service})
      : _service = service ?? const CustomerLocationService(),
        super(const CustomerLocationState());

  final CustomerLocationService _service;

  Future<void> bootstrap() async {
    if (state.status != CustomerLocationStatus.initial) return;
    await useCurrentLocation();
  }

  Future<ServiceLocation?> useCurrentLocation() async {
    state = CustomerLocationState(
      status: CustomerLocationStatus.fetching,
      location: state.location,
    );
    try {
      final location = await _service.current();
      state = CustomerLocationState(
        status: CustomerLocationStatus.ready,
        location: location,
      );
      return location;
    } on CustomerLocationException catch (error) {
      state = CustomerLocationState(
        status: CustomerLocationStatus.needsSelection,
        location: state.location,
        message: error.message,
      );
      return null;
    } catch (_) {
      state = CustomerLocationState(
        status: CustomerLocationStatus.needsSelection,
        location: state.location,
        message: 'Choose your service location before booking.',
      );
      return null;
    }
  }

  Future<ServiceLocation?> useAddress(String address) async {
    state = CustomerLocationState(
      status: CustomerLocationStatus.fetching,
      location: state.location,
    );
    try {
      final location = await _service.resolveAddress(address);
      state = CustomerLocationState(
        status: CustomerLocationStatus.ready,
        location: location,
      );
      return location;
    } on CustomerLocationException catch (error) {
      state = CustomerLocationState(
        status: CustomerLocationStatus.needsSelection,
        location: state.location,
        message: error.message,
      );
      return null;
    }
  }
}
