import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart'; // Pour la ligne bleue

void main() {
  runApp(const MonGPSRadarApp());
}

class MonGPSRadarApp extends StatelessWidget {
  const MonGPSRadarApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GPS Anti-Radar',
      theme: ThemeData.dark(),
      home: const CarteScreen(),
    );
  }
}

class CarteScreen extends StatefulWidget {
  const CarteScreen({Key? key}) : super(key: key);

  @override
  _CarteScreenState createState() => _CarteScreenState();
}

class _CarteScreenState extends State<CarteScreen> {
  final MapController _mapController = MapController();
  LatLng maPosition = const LatLng(43.6046, 1.4442);
  List<Marker> mesRadars = [];
  bool gpsActif = false;

  // --- NOUVELLES VARIABLES ---
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée

  @override
  void initState() {
    super.initState();
    _activerGPS();
  }

  Future<void> _activerGPS() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) {
      setState(() {
        maPosition = LatLng(position.latitude, position.longitude);
        gpsActif = true;
      });
      _mapController.move(maPosition, 15.0);
      chargerRadars();
      
      // Si on a une destination, on recalcule la route en roulant
      if (destination != null) {
        calculerRoute(maPosition, destination!);
      }
    });
  }

  // --- FONCTION RECHERCHE (LOOK WAZE) ---
  Future<void> _rechercherDestination(String texte) async {
    final url = Uri.parse("https://photon.komoot.io/api/?q=$texte&limit=1");
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        if (data['features'].isNotEmpty) {
          final coords = data['features'][0]['geometry']['coordinates'];
          setState(() {
            destination = LatLng(coords[1], coords[0]);
          });
          calculerRoute(maPosition, destination!);
        }
      }
    } catch (e) { print("Erreur recherche: $e"); }
  }

  // --- FONCTION VALHALLA (L'ITINÉRAIRE) ---
  Future<void> calculerRoute(LatLng depart, LatLng arrivee) async {
    final url = Uri.parse('https://valhalla.zeusmos.fr/route');
    final corps = json.encode({
      "locations": [
        {"lat": depart.latitude, "lon": depart.longitude},
        {"lat": arrivee.latitude, "lon": arrivee.longitude}
      ],
      "costing": "auto",
      "units": "kilometers"
    });

    try {
      final reponse = await http.post(url, body: corps);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final shape = data['trip']['legs'][0]['shape']; 
        
        List<PointLatLng> result = PolylinePoints.decodePolyline(shape);
        setState(() {
          pointsItineraire = result.map((p) => LatLng(p.latitude, p.longitude)).toList();
        });
        
        if (result.isNotEmpty) {
          setState(() {
            pointsItineraire = result.map((p) => LatLng(p.latitude, p.longitude)).toList();
          });
          
          _mapController.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(pointsItineraire),
            padding: const EdgeInsets.all(50),
          ));
        }
      }
    } catch (e) { print("Erreur Valhalla: $e"); }
  }

  Future<void> chargerRadars() async {
    final url = Uri.parse('https://gps-api.zeusmos.fr/radars?lat=${maPosition.latitude}&lon=${maPosition.longitude}&rayon_km=15');
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final List radarsAPI = data['radars'];
        setState(() {
          mesRadars = radarsAPI.map((radar) {
            return Marker(
              point: LatLng(radar['latitude'], radar['longitude']),
              width: 50, height: 50,
              child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 30),
            );
          }).toList();
        });
      }
    } catch (e) { print("Erreur API: $e"); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack( // Stack permet de superposer la barre de recherche sur la carte
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: maPosition, initialZoom: 15.0),
            children: [
              TileLayer(
                urlTemplate: 'https://tileserver.zeusmos.fr/styles/osm-liberty/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.jeremy.gps',
              ),
              // LA LIGNE BLEUE
              PolylineLayer(
                polylines: [
                  if (pointsItineraire.isNotEmpty)
                    Polyline(
                      points: pointsItineraire, 
                      color: Colors.blueAccent, 
                      strokeWidth: 6.0,
                    ),
                ],
              ),
              MarkerLayer(markers: mesRadars),
              MarkerLayer(
                markers: [
                  Marker(
                    point: maPosition,
                    child: const Icon(Icons.navigation, color: Colors.blueAccent, size: 40),
                  ),
                  if (destination != null)
                    Marker(
                      point: destination!,
                      child: const Icon(Icons.location_on, color: Colors.green, size: 45),
                    ),
                ],
              ),
            ],
          ),
          
          // LA BARRE DE RECHERCHE (STYLE WAZE / MAGIC EARTH)
          Positioned(
            top: 50, left: 20, right: 20,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10)],
              ),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: "Où allez-vous ?",
                  prefixIcon: Icon(Icons.search, color: Colors.blueAccent),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 15),
                ),
                onSubmitted: (value) => _rechercherDestination(value),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _mapController.move(maPosition, 15.0),
        child: const Icon(Icons.my_location),
      ),
    );
  }
}