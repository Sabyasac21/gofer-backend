import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class ServiceLocation {
  const ServiceLocation({
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.verified,
    this.fromLiveLocation = false,
    this.accuracyMeters,
  });

  static const fallback = ServiceLocation(
    address: 'Select service location',
    latitude: 28.6274,
    longitude: 77.3723,
    verified: false,
  );

  final String address;
  final double latitude;
  final double longitude;
  final bool verified;
  final bool fromLiveLocation;
  final double? accuracyMeters;

  ServiceLocation copyWith({
    String? address,
    double? latitude,
    double? longitude,
    bool? verified,
    bool? fromLiveLocation,
    double? accuracyMeters,
  }) =>
      ServiceLocation(
        address: address ?? this.address,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        verified: verified ?? this.verified,
        fromLiveLocation: fromLiveLocation ?? this.fromLiveLocation,
        accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      );
}

class CustomerLocationException implements Exception {
  const CustomerLocationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CustomerLocationService {
  const CustomerLocationService();

  Future<ServiceLocation> current({bool requestPermission = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const CustomerLocationException(
        'Turn on Location Services to use your live service location.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && requestPermission) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const CustomerLocationException(
        'Location permission was not granted. You can enter an address instead.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const CustomerLocationException(
        'Location permission is blocked. Enable it in app settings or enter an address.',
      );
    }

    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (_) {
      position = await Geolocator.getLastKnownPosition();
    }
    if (position == null) {
      throw const CustomerLocationException(
        'Your live location is temporarily unavailable. Enter the address manually.',
      );
    }
    final address = await _addressFor(position.latitude, position.longitude);
    return ServiceLocation(
      address: address,
      latitude: position.latitude,
      longitude: position.longitude,
      verified: true,
      fromLiveLocation: true,
      accuracyMeters: position.accuracy,
    );
  }

  Future<ServiceLocation> resolveAddress(String address) async {
    final clean = address.trim();
    if (clean.length < 5) {
      throw const CustomerLocationException(
        'Enter a complete service address.',
      );
    }
    if (kIsWeb) {
      throw const CustomerLocationException(
        'Address search is available in the Android and iOS apps. Use live location while testing on web.',
      );
    }
    try {
      final matches = await locationFromAddress(clean);
      if (matches.isEmpty) throw StateError('No match');
      return ServiceLocation(
        address: clean,
        latitude: matches.first.latitude,
        longitude: matches.first.longitude,
        verified: true,
      );
    } catch (_) {
      throw const CustomerLocationException(
        'We could not find that address. Add area, city and postcode, then retry.',
      );
    }
  }

  Future<String> _addressFor(double latitude, double longitude) async {
    if (!kIsWeb) {
      try {
        final places = await placemarkFromCoordinates(latitude, longitude);
        if (places.isNotEmpty) {
          final place = places.first;
          final parts = [
            place.name,
            place.street,
            place.subLocality,
            place.locality,
            place.postalCode,
          ].whereType<String>().map((part) => part.trim()).where(
                (part) => part.isNotEmpty,
              );
          final unique = <String>[];
          for (final part in parts) {
            if (!unique.contains(part)) unique.add(part);
          }
          if (unique.isNotEmpty) return unique.join(', ');
        }
      } catch (_) {
        // Coordinates remain a valid verified fallback.
      }
    }
    return 'Current location · ${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }
}
