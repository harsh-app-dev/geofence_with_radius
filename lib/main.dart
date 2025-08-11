import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:location/location.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

/// Simple LatLng class for geofence calculations.
class LatLng {
  final double latitude;
  final double longitude;

  LatLng(this.latitude, this.longitude);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables (.env file)
  await dotenv.load(fileName: ".env");

  // Retrieve Mapbox access token from .env
  final String? accessToken = dotenv.env['MAPBOX_ACCESS_TOKEN'];
  if (accessToken == null || accessToken.isEmpty) {
    throw Exception('Mapbox access token missing in .env file');
  }

  // Set Mapbox token globally for the SDK
  MapboxOptions.setAccessToken(accessToken);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Geofence with Live Location',
    theme: ThemeData(primarySwatch: Colors.indigo),
    home: const MapScreen(),
  );
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointManager;
  PolygonAnnotationManager? _polygonManager;
  LocationData? _currentLocation;
  final Location _location = Location();

  late final FlutterLocalNotificationsPlugin _localNotificationsPlugin;

  bool _showLoading = true;
  String _error = '';

  // Geofence params
  final LatLng _geofenceCenter = LatLng(30.723398, 76.847850);
  final double _geofenceRadiusMeters = 50.0;
  late final List<LatLng> _geofencePolygonCoords;

  bool? _insideGeofence; // null on start
  bool _firstLocationUpdate = true;

  @override
  void initState() {
    super.initState();

    _geofencePolygonCoords = _createCirclePolygon(_geofenceCenter, _geofenceRadiusMeters);

    _initLocalNotifications();
    _initLocation();
  }

  /// Initialize Flutter local notifications and request Android permission.
  Future<void> _initLocalNotifications() async {
    _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _localNotificationsPlugin.initialize(initSettings);

    if (Platform.isAndroid) {
      final androidImpl = _localNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        final bool? granted = await androidImpl.requestNotificationsPermission();
        if (granted != true) {
          debugPrint('Notification permission denied or not granted on Android');
        }
      }
    }
  }

  Future<void> _showNotification(String message) async {
    const androidDetails = AndroidNotificationDetails(
      'geofence_channel_id',
      'Geofence Notifications',
      channelDescription: 'Notifications about geofence entry and exit',
      importance: Importance.max,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();

    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _localNotificationsPlugin.show(0, 'Geofence Alert', message, details);
  }

  /// Retry helper to work around PlatformException on location.serviceEnabled().
  Future<bool> _serviceEnabledWithRetry({int maxRetries = 10, Duration delay = const Duration(milliseconds: 200)}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        final enabled = await _location.serviceEnabled();
        return enabled;
      } on PlatformException catch (e) {
        await Future.delayed(delay);
      }
    }
    return false;
  }

  Future<void> _initLocation() async {
    try {
      // Ask for location permission first
      var status = await Permission.locationWhenInUse.status;
      if (status.isDenied || status.isRestricted) {
        status = await Permission.locationWhenInUse.request();
      }

      if (status.isPermanentlyDenied) {
        // User previously chose "Don't ask again"
        await openAppSettings();
        return;
      }

      if (!status.isGranted) {
        // Permission still not granted
        return;
      }

      // Make sure location services are enabled
      bool serviceEnabled = await _serviceEnabledWithRetry();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
        if (!serviceEnabled) return;
      }

      // Optional: request background location (Android)
      if (Platform.isAndroid) {
        await Permission.locationAlways.request();
      }

      // Configure location updates
      await _location.changeSettings(
        accuracy: LocationAccuracy.high,
        interval: 3000,
        distanceFilter: 3,
      );

      // Listen to location changes
      _location.onLocationChanged.listen((loc) {
        if (!mounted) return;
        setState(() => _currentLocation = loc);
        _updateMarker();
        if (loc.latitude != null && loc.longitude != null) {
          _checkGeofence(LatLng(loc.latitude!, loc.longitude!));
        }
      });

      // Get current location
      _currentLocation = await _location.getLocation();
      if (_currentLocation?.latitude != null && _currentLocation?.longitude != null) {
        _checkGeofence(LatLng(_currentLocation!.latitude!, _currentLocation!.longitude!));
      }
    } finally {
      setState(() => _showLoading = false);
    }
  }
  Future<void> _showPermissionDialog() async {
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
            'This app needs location permissions to work properly. '
                'Please enable location permissions in app settings.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Geofence with Live Location')),
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey("mapbox"),
            cameraOptions: CameraOptions(
              center: Point(coordinates: Position(_geofenceCenter.longitude, _geofenceCenter.latitude)),
              zoom: 16,
            ),
            onMapCreated: _onMapCreated,
          ),
          if (_showLoading) const Center(child: CircularProgressIndicator()),

          // Live Altitude display
          Positioned(
            top: 20,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _currentLocation?.altitude != null
                    ? 'Altitude: ${_currentLocation!.altitude!.toStringAsFixed(2)} m'
                    : 'Altitude: --',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }


  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    _polygonManager = await mapboxMap.annotations.createPolygonAnnotationManager();
    _pointManager = await mapboxMap.annotations.createPointAnnotationManager();

    await _drawGeofencePolygon();
    _updateMarker();
  }

  Future<void> _drawGeofencePolygon() async {
    if (_polygonManager == null) return;

    await _polygonManager!.deleteAll();

    final polygonOpts = PolygonAnnotationOptions(
      geometry: Polygon(coordinates: [
        _geofencePolygonCoords.map((e) => Position(e.longitude, e.latitude)).toList()
      ]),
      fillColor: Colors.blue.withOpacity(0.3).value,
      fillOutlineColor: Colors.blue.value,
    );

    await _polygonManager!.create(polygonOpts);
  }

  Future<void> _updateMarker() async {
    if (_currentLocation == null || _pointManager == null) return;
    if (_currentLocation!.latitude == null || _currentLocation!.longitude == null) return;

    await _pointManager!.deleteAll();

    final ByteData bytes = await rootBundle.load('assets/marker.png');
    final Uint8List imgBytes = bytes.buffer.asUint8List();

    final options = PointAnnotationOptions(
      geometry: Point(coordinates: Position(_currentLocation!.longitude!, _currentLocation!.latitude!)),
      image: imgBytes,
      iconSize: 1,
      textField: "You",
      textOffset: [0, -1.5],
    );

    await _pointManager!.create(options);

    if (_firstLocationUpdate) {
      await _mapboxMap?.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(_currentLocation!.longitude!, _currentLocation!.latitude!)),
          zoom: 16,
        ),
        MapAnimationOptions(duration: 1000),
      );
      _firstLocationUpdate = false;
    }
  }

  void _checkGeofence(LatLng userLocation) {
    final insidePolygon = _pointInPolygon(userLocation, _geofencePolygonCoords);

    // Check altitude if available (elevation above sea level)
    bool belowCeiling = true;
    if (_currentLocation?.altitude != null) {
      const groundFloorElevation = 320.0; // meters above sea level
      const ceilingHeight = 5.0; // meters (building height)
      const maxAltitude = groundFloorElevation + ceilingHeight; // 380m
      belowCeiling = (_currentLocation!.altitude! <= maxAltitude);
    }

    final inside = insidePolygon && belowCeiling;

    if (_insideGeofence == null) {
      _insideGeofence = inside;
      return;
    }

    if (inside != _insideGeofence) {
      _insideGeofence = inside;
      String message;
      if (inside) {
        message = "Entered geofence area";
      } else if (!belowCeiling) {
        message = "Exited geofence area: above ceiling";
      } else {
        message = "Exited geofence area";
      }
      _showNotification(message);
    }
  }

  List<LatLng> _createCirclePolygon(LatLng center, double radiusMeters, {int points = 64}) {
    final coords = <LatLng>[];
    const earthRadius = 6371000.0;

    final latRad = _degToRad(center.latitude);
    final lonRad = _degToRad(center.longitude);

    for (int i = 0; i <= points; i++) {
      final angle = 2 * pi * i / points;

      final latOffset = asin(sin(latRad) * cos(radiusMeters / earthRadius) +
          cos(latRad) * sin(radiusMeters / earthRadius) * cos(angle));
          final lonOffset = lonRad +
          atan2(
          sin(angle) * sin(radiusMeters / earthRadius) * cos(latRad),
          cos(radiusMeters / earthRadius) - sin(latRad) * sin(latOffset),
    );

    coords.add(LatLng(_radToDeg(latOffset), _radToDeg(lonOffset)));
  }
    return coords;
  }

  double _degToRad(double deg) => deg * pi / 180;

  double _radToDeg(double rad) => rad * 180 / pi;

  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    int intersections = 0;

    for (int i = 0; i < polygon.length - 1; i++) {
      final a = polygon[i];
      final b = polygon[i + 1];
      if (_rayIntersectsSegment(point, a, b)) {
        intersections++;
      }
    }

    return (intersections % 2) == 1;
  }

  bool _rayIntersectsSegment(LatLng p, LatLng a, LatLng b) {
    final px = p.longitude;
    double py = p.latitude;
    final ax = a.longitude;
    final ay = a.latitude;
    final bx = b.longitude;
    final by = b.latitude;

    if (ay > by) return _rayIntersectsSegment(p, b, a);
    if (py == ay || py == by) py += 0.00000001;
    if (py > by || py < ay || px > max(ax, bx)) return false;
    if (px < min(ax, bx)) return true;

    final red = (px - ax) / (bx - ax);
    final blue = (py - ay) / (by - ay);
    return red >= blue;
  }

  @override
  void dispose() {
    _location.onLocationChanged.drain();
    super.dispose();
  }
}