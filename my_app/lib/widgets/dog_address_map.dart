import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Small static map on the dog profile pinning the dog's home address, using
/// the same OpenStreetMap tiles as the staff pickup map. Shown only when the
/// dog has geocoded coordinates. Tapping opens the location in the device's
/// maps app — the map itself doesn't pan/zoom, so it never fights the
/// profile's page scroll.
class DogAddressMap extends StatelessWidget {
  final double latitude;
  final double longitude;

  const DogAddressMap({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  Future<void> _openInMaps() async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* best effort */}
  }

  @override
  Widget build(BuildContext context) {
    final position = LatLng(latitude, longitude);
    return Container(
      width: double.infinity,
      height: 180,
      margin: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: position,
                initialZoom: 15,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.paws4thoughtdogs.app',
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: position,
                    width: 40,
                    height: 40,
                    // Top-center alignment puts the pin's tip on the address.
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.location_pin,
                        color: Colors.red, size: 40),
                  ),
                ]),
                const SimpleAttributionWidget(
                  source: Text('OpenStreetMap contributors'),
                ),
              ],
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: _openInMaps),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
