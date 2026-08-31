import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../providers/customer_location_provider.dart';
import '../services/customer_location_service.dart';
import '../services/google_maps_loader.dart';

class ServiceLocationPicker extends ConsumerWidget {
  const ServiceLocationPicker({
    super.key,
    required this.location,
    required this.onChanged,
  });

  final ServiceLocation location;
  final ValueChanged<ServiceLocation> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = location.verified;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color:
                  selected ? const Color(0xFF9CDDD5) : const Color(0xFFD7E2E0)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x12073532), blurRadius: 16, offset: Offset(0, 6))
          ],
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            button: true,
            label: selected
                ? 'Service location ${location.address}. Change location'
                : 'Add service location',
            child: InkWell(
              key: const ValueKey('service-location-picker'),
              onTap: () => _showPicker(context, ref),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                              color: Color(0xFFE7F7F4), shape: BoxShape.circle),
                          child: const Icon(Icons.location_on_rounded,
                              color: Color(0xFF08786F))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(
                                selected
                                    ? 'Service location'
                                    : 'Add service location',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text(location.address,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(0xFF526361), height: 1.35)),
                          ])),
                      TextButton(
                          onPressed: () => _showPicker(context, ref),
                          child: Text(selected ? 'Change' : 'Add')),
                    ]),
              ),
            ),
          ),
          if (selected) ...[
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ServiceLocationMapPreview(location: location)),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(children: [
                Icon(Icons.verified_rounded,
                    size: 18, color: Color(0xFF08786F)),
                SizedBox(width: 7),
                Expanded(
                    child: Text(
                        'Pin verified — workers receive the exact location after you confirm.',
                        style: TextStyle(
                            color: Color(0xFF08786F),
                            fontSize: 12,
                            fontWeight: FontWeight.w700))),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _showPicker(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<ServiceLocation>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _LocationSheet(),
    );
    if (result != null) onChanged(result);
  }
}

class _ServiceLocationMapPreview extends StatefulWidget {
  const _ServiceLocationMapPreview({required this.location});

  final ServiceLocation location;

  @override
  State<_ServiceLocationMapPreview> createState() =>
      _ServiceLocationMapPreviewState();
}

class _ServiceLocationMapPreviewState
    extends State<_ServiceLocationMapPreview> {
  GoogleMapController? _controller;
  bool _showRecenter = false;

  ServiceLocation get location => widget.location;

  void _handleCameraMove(CameraPosition position) {
    final distance = Geolocator.distanceBetween(
      position.target.latitude,
      position.target.longitude,
      location.latitude,
      location.longitude,
    );
    final shouldShow = distance > 75;
    if (shouldShow != _showRecenter && mounted) {
      setState(() => _showRecenter = shouldShow);
    }
  }

  Future<void> _recenter() async {
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(location.latitude, location.longitude),
        16.5,
      ),
    );
    if (mounted) setState(() => _showRecenter = false);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinates = LatLng(location.latitude, location.longitude);
    return Semantics(
      label: 'Service location map for ${location.address}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          key: const ValueKey('service-location-map-preview'),
          height: 178,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (kIsWeb && !googleMapsAvailable)
                const ColoredBox(
                  color: Color(0xFFE7F1EF),
                  child: Center(
                    child: Icon(
                      Icons.map_outlined,
                      size: 42,
                      color: Color(0xFF08786F),
                    ),
                  ),
                )
              else
                GoogleMap(
                  key: ValueKey(
                    'service-map-${location.latitude}-${location.longitude}',
                  ),
                  initialCameraPosition: CameraPosition(
                    target: coordinates,
                    zoom: 16.5,
                  ),
                  onMapCreated: (controller) => _controller = controller,
                  onCameraMove: _handleCameraMove,
                  markers: {
                    Marker(
                      markerId: const MarkerId('service-location'),
                      position: coordinates,
                      infoWindow: const InfoWindow(
                        title: 'Service request location',
                      ),
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueGreen,
                      ),
                    ),
                  },
                  gestureRecognizers: const {
                    Factory<OneSequenceGestureRecognizer>(
                      EagerGestureRecognizer.new,
                    ),
                  },
                  circles: {
                    Circle(
                      circleId: const CircleId('service-location-area'),
                      center: coordinates,
                      radius: location.fromLiveLocation
                          ? (location.accuracyMeters ?? 20).clamp(10, 100)
                          : 12,
                      fillColor: const Color(0x2808786F),
                      strokeColor: const Color(0xFF08786F),
                      strokeWidth: 1,
                    ),
                  },
                  compassEnabled: true,
                  mapToolbarEnabled: false,
                  myLocationEnabled: location.fromLiveLocation,
                  myLocationButtonEnabled: false,
                  rotateGesturesEnabled: true,
                  scrollGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  zoomControlsEnabled: true,
                  zoomGesturesEnabled: true,
                ),
              if (_showRecenter)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.88),
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: IconButton(
                      key: const ValueKey('recenter-service-location'),
                      tooltip: 'Recenter on your location',
                      onPressed: _recenter,
                      icon: const Icon(
                        Icons.my_location_rounded,
                        color: Color(0xFF08786F),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationSheet extends ConsumerStatefulWidget {
  const _LocationSheet();

  @override
  ConsumerState<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends ConsumerState<_LocationSheet> {
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(customerLocationProvider);
    final loading = state.status == CustomerLocationStatus.fetching;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCAD5D3),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Where do you need the service?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 5),
            const Text(
              'Workers are matched and routed using this location.',
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              key: const ValueKey('use-live-location'),
              onPressed: loading
                  ? null
                  : () async {
                      final result = await ref
                          .read(customerLocationProvider.notifier)
                          .useCurrentLocation();
                      if (result != null && context.mounted) {
                        Navigator.pop(context, result);
                      }
                    },
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_rounded),
              label: const Text('Use my live location'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('or enter an address'),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
            ),
            TextField(
              key: const ValueKey('manual-service-address'),
              controller: _addressController,
              minLines: 2,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Complete service address',
                hintText: 'Flat, building, street, area, city and postcode',
                prefixIcon: Icon(Icons.home_outlined),
              ),
            ),
            if (state.message != null) ...[
              const SizedBox(height: 10),
              Text(
                state.message!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('confirm-service-address'),
              onPressed: loading
                  ? null
                  : () async {
                      final result = await ref
                          .read(customerLocationProvider.notifier)
                          .useAddress(_addressController.text);
                      if (result != null && context.mounted) {
                        Navigator.pop(context, result);
                      }
                    },
              child: const Text('Set service location'),
            ),
          ],
        ),
      ),
    );
  }
}
