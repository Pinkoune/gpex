import 'package:flutter/material.dart';
import 'package:maplibre_gl/mapbox_gl.dart'; // Remplace flutter_map et latlong2
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui'; // Pour le BackdropFilter (Glassmorphism)
import 'package:geolocator/geolocator.dart';

const String tomtomApiKey = "gCm05RjVrOc3Ew1WlUgn9zrbjImAKW9n";
const String mapTilerApiKey = "iK3uh8aiosMMylpf5nhx";

class TrafficSegment {
  final int startIndex;
  final int endIndex;
  final Color color;
  TrafficSegment(this.startIndex, this.endIndex, this.color);
}

void main() {
  runApp(const MonGPSRadarApp());
}

class MonGPSRadarApp extends StatelessWidget {
  const MonGPSRadarApp({super.key});

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
  const CarteScreen({super.key});

  @override
  State<CarteScreen> createState() => _CarteScreenState();
}

class _CarteScreenState extends State<CarteScreen> { // Enlevé TickerProviderStateMixin
  MaplibreMapController? _mapController;
  String instructionActive = "Suivez l'itinéraire";
  bool _estCartePrete = false; // Flag pour s'assurer que la carte est prête
  LatLng maPosition = const LatLng(43.6046, 1.4442);
  List<dynamic> mesRadarsData = [];
  bool gpsActif = false;
  // --- NOUVELLES VARIABLES ---
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée
  bool modeNavigation = false; // Mode GPS Waze-like activé
  double vitesseKmh = 0.0; // Vitesse du véhicule
  double vitesseLimiteCible = 0.0; // Vitesse réglementée max
  List<int> pointsSpeedLimit = []; // Limitations par Shape Index
  List<TrafficSegment> segmentsTrafic = []; // Segments de couleurs calculés

  
  double radarProcheDistance = double.infinity; // Radar info




  // Aperçu du trajet (Google Maps style)
  bool modeApercuTrajet = false;
  String transportMode = 'auto'; // 'auto', 'bicycle', 'pedestrian'
  String distanceTextApercu = "";
  String etaTextApercu = "";

  bool afficherEssence = false;
  bool afficherParking = false;
  bool afficherBornes = false;
  bool afficherTourisme = false;
  List<Circle> markersEssence = [];
  List<Circle> markersParking = [];
  List<Circle> markersBornes = [];
  List<Circle> markersTourisme = [];
  List<Circle> mesRadars = [];
  List<dynamic> dataEssence = [];
  List<dynamic> dataParking = [];
  List<dynamic> dataBornes = [];
  List<dynamic> dataTourisme = [];

  // --- RECHERCHE ---
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<dynamic> _suggestions = [];

  @override
  void initState() {
    super.initState();
    _activerGPS();
    _searchFocus.addListener(() {
      setState(() {}); // Rebuild when focus changes
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _activerGPS() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    // 1. Lancer le stream pour le suivi en temps réel TOUT DE SUITE
    // (Ainsi, même si getCurrentPosition bloque, le suivi est armé)
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation, // Précision maximale !
        distanceFilter: 2, // Pour plus de fluidité, filter à 2m
      ),
    ).listen((Position position) {
      if (!mounted) return;
      setState(() {
        maPosition = LatLng(position.latitude, position.longitude);
        vitesseKmh = position.speed > 0 ? position.speed * 3.6 : 0.0;
        gpsActif = true;
      });

      if (_estCartePrete) {
        if (modeNavigation) {
          double targetZoom = 18.0;
          if (vitesseKmh > 80) {
            targetZoom = 15.5;
          } else if (vitesseKmh > 40) {
            targetZoom = 16.5;
          }
          
          double targetRot = position.heading > 0 ? position.heading : 0.0;
          
          // MaplibreGL permet nativement de gérer l'inclinaison (tilt) et le cap (bearing) !
          // On n'a plus besoin du trick de calcul d'offset puisque Maplibre le gère seul
          _mapController?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: maPosition,
                zoom: targetZoom,
                bearing: targetRot,
                tilt: 55.0, // Inclinaison 3D style Apple Maps
              ),
            ),
          );
        } else {
           // Sans anim pour coller au basique de la 2D ? 
           //_mapController?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: maPosition, tilt: 0.0, bearing: 0.0)));
        }
      }
      chargerRadars();
      
      // Radar Alert Logic
      double minDistRadar = double.infinity;
      if (modeNavigation && gpsActif && mesRadarsData.isNotEmpty) {
        for (var radar in mesRadarsData) {
          double dist = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              radar['lat'], radar['lon']);
          
          if (dist <= 800) { // Afficher jusqu'à 800m
             double bearing = Geolocator.bearingBetween(
                position.latitude, position.longitude,
                radar['lat'], radar['lon']);
             double angleDiff = (bearing - position.heading).abs();
             if (angleDiff > 180) angleDiff = 360 - angleDiff;
             if (angleDiff <= 60) {
               if (dist < minDistRadar) minDistRadar = dist;
             }
          }
        }
      }
      setState(() {
        radarProcheDistance = minDistRadar;
      });

      if (destination != null && pointsItineraire.isNotEmpty && modeNavigation) {
        // --- REAL TIME ETA / RECALCULATION ---
        double minDistanceToRoute = double.infinity;
        int minIndex = -1;

        // Trouver le point le plus proche sur le tracé restant (pour performance, on chercherait mieux)
        for (int i = 0; i < pointsItineraire.length; i++) {
          double dist = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              pointsItineraire[i].latitude, pointsItineraire[i].longitude);
          if (dist < minDistanceToRoute) {
            minDistanceToRoute = dist;
            minIndex = i;
          }
        }

        if (minDistanceToRoute > 100) { // Déviation > 100m = recalcul route
             debugPrint("🚩 Déviation détectée ($minDistanceToRoute m). Recalcul de l'itinéraire !");
             pointsItineraire.clear();
             pointsSpeedLimit.clear();
             segmentsTrafic.clear();
             calculerRoute(maPosition, destination!, transportMode);
        } else if (minIndex != -1) {
            // Update Speed Limit Target
            double newLimit = 0.0;
            if (minIndex < pointsSpeedLimit.length) {
              newLimit = pointsSpeedLimit[minIndex].toDouble();
            }

            // Distance restante approximative en cumulant les segments suivants
            double distLeftMeters = 0;
            for (int i = minIndex; i < pointsItineraire.length - 1; i++) {
                distLeftMeters += Geolocator.distanceBetween(
                     pointsItineraire[i].latitude, pointsItineraire[i].longitude,
                     pointsItineraire[i+1].latitude, pointsItineraire[i+1].longitude,
                );
            }
            
            // ETA Basé sur Vitesse Valhalla ou Standard => Moyenne 50 km/h urbain = 13.8 m/s
            double speedMs = vitesseKmh > 0 ? position.speed : 13.8; 
            if(speedMs < 5.0 && transportMode == 'auto') speedMs = 13.8; // default to avoid infinite ETA at stop
            
            int secondsLeft = (distLeftMeters / speedMs).round();
            int hours = secondsLeft ~/ 3600;
            int mins = (secondsLeft % 3600) ~/ 60;

            String newEta = hours > 0 ? "$hours h ${mins.toString().padLeft(2, '0')} min" : "$mins min";
            String newDist = distLeftMeters > 1000 
                ? "${(distLeftMeters / 1000).toStringAsFixed(1)} km" 
                : "${distLeftMeters.round()} m";

            if (newEta != etaTextApercu || newDist != distanceTextApercu || newLimit != vitesseLimiteCible) {
               setState(() {
                 etaTextApercu = newEta;
                 distanceTextApercu = newDist; // Update Panel
                 vitesseLimiteCible = newLimit;
               });
            }
        }
      }
    });

    // 2. Tenter d'obtenir la dernière position connue pour un fix ultra-rapide
    try {
      Position? knownPosition = await Geolocator.getLastKnownPosition();
      if (knownPosition != null && mounted) {
        setState(() {
          maPosition = LatLng(knownPosition.latitude, knownPosition.longitude);
          vitesseKmh = knownPosition.speed > 0
              ? knownPosition.speed * 3.6
              : 0.0;
          gpsActif = true;
        });
        if (_estCartePrete) {
          _mapController?.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 15.0));
        }
      }
    } catch (_) {}

    // 3. Forcer une position fraîche avec un TIMEOUT
    // Sans le timeout, getCurrentPosition peut bloquer à l'infini en intérieur sur Android
    try {
      Position positionInitiale = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 5));

      if (mounted) {
        setState(() {
          maPosition = LatLng(
            positionInitiale.latitude,
            positionInitiale.longitude,
          );
          vitesseKmh = positionInitiale.speed > 0
              ? positionInitiale.speed * 3.6
              : 0.0;
          gpsActif = true;
        });
        if (_estCartePrete) {
          _mapController?.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 15.0));
        }
        chargerRadars();
      }
    } catch (e) {
      debugPrint("Timeout ou erreur surGetCurrentPosition initiale: $e");
    }
  }

  Widget _buildBoutonItineraire(LatLng cible, String nom) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent.shade700,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
          icon: const Icon(Icons.navigation, color: Colors.white),
          label: const Text("Y aller", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          onPressed: () {
            Navigator.pop(context); // Ferme la petite fenêtre du bas
            _searchController.text = nom; // Met le nom dans la barre de recherche
            setState(() {
              destination = cible;
              modeApercuTrajet = true; // Ouvre le panneau "Démarrer"
            });
            calculerRoute(maPosition, destination!, transportMode);
          },
        ),
      ),
    );
  }

  // --- TRAFFIC EN GEOJSON (MAPLIBRE GL) ---
  void _updateRouteGeoJson() async {
    if (_mapController == null || !_estCartePrete) return;

    if (pointsItineraire.isEmpty) {
      await _mapController!.setGeoJsonSource("route-source", {
        "type": "FeatureCollection",
        "features": []
      });
      return;
    }

    List<Map<String, dynamic>> features = [];

    // 1. Ligne Blanche en Contour (Style Apple Maps)
    List<List<double>> fullCoords = pointsItineraire.map((p) => [p.longitude, p.latitude]).toList();
    features.add({
      "type": "Feature",
      "geometry": {
        "type": "LineString",
        "coordinates": fullCoords
      },
      "properties": {
        "color": "#FFFFFF",
        "isBorder": true
      }
    });

    // 2. La route principale (Bleue unie ou Multicolore selon le trafic)
    if (segmentsTrafic.isEmpty) {
      features.add({
        "type": "Feature",
        "geometry": {
          "type": "LineString",
          "coordinates": fullCoords
        },
        "properties": {
          "color": "#007AFF", // Bleu natif iOS
          "isBorder": false
        }
      });
    } else {
      for (var segment in segmentsTrafic) {
        if (segment.startIndex >= 0 && segment.endIndex < pointsItineraire.length && segment.startIndex < segment.endIndex) {
          List<List<double>> segCoords = pointsItineraire
              .sublist(segment.startIndex, segment.endIndex + 1)
              .map((p) => [p.longitude, p.latitude])
              .toList();
          
          String hexColor = '#${(segment.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

          // --- C'EST ICI QU'ON DESSINE LE MORCEAU DE COULEUR ---
          features.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": segCoords
            },
            "properties": {
              "color": hexColor,
              "isBorder": false
            }
          });
        }
      }
    }

    // 3. --- AJOUT DU POINT D'ARRIVÉE (Une seule fois à la toute fin) ---
    if (destination != null && pointsItineraire.isNotEmpty) {
      features.add({
        "type": "Feature",
        "geometry": {
          "type": "Point",
          "coordinates": [destination!.longitude, destination!.latitude]
        },
        "properties": {
          "isDestination": true,
          "isBorder": false
        }
      });
    }

    // Mise à jour de la source sur la carte MapLibre
    await _mapController!.setGeoJsonSource("route-source", {
      "type": "FeatureCollection",
      "features": features
    });
  }

  // --- SUGGESTIONS TEMPS RÉEL ---
  Future<void> _rechercherSuggestions(String texte) async {
    debugPrint('🔎 _rechercherSuggestions appelé avec : "$texte"');
    if (texte.trim().length < 2) {
      debugPrint('   -> Texte trop court, nettoyage des suggestions');
      setState(() => _suggestions = []);
      return;
    }
    final url = Uri.parse(
      'https://photon.komoot.io/api/?q=${Uri.encodeComponent(texte)}&lat=${maPosition.latitude}&lon=${maPosition.longitude}&limit=5&lang=fr',
    );
    debugPrint('   -> Appel API: $url');
    try {
      final reponse = await http.get(
        url,
        headers: {'User-Agent': 'gpex_app/1.0', 'Accept': 'application/json'},
      );
      debugPrint('   -> Code HTTP: ${reponse.statusCode}');
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final features = data['features'] as List;
        debugPrint('   -> ${features.length} résultats trouvés');
        setState(() => _suggestions = features);
      }
    } catch (e) {
      debugPrint('   ❌ Erreur API suggestions: $e');
    }
  }

  // --- SÉLECTION D'UNE SUGGESTION ---
  Future<void> _selectionnerSuggestion(dynamic feature) async {
    final coords = feature['geometry']['coordinates'];
    final props = feature['properties'];
    final nom = props['name'] ?? props['city'] ?? 'Destination';
    _searchController.text = nom;
    _searchFocus.unfocus();
    setState(() {
      destination = LatLng(coords[1], coords[0]);
      _suggestions = [];
    });

    // Attendre le calcul de la route pour qu'elle s'affiche sur la carte globale
    await calculerRoute(maPosition, destination!, transportMode);

    // On passe en map rotative si et seulement si l'utilisateur clique sur démarrer
    setState(() {
      modeApercuTrajet = true;
    });

    // Centrer la caméra pour qu'on voit l'intégralité du trajet
    if (pointsItineraire.isNotEmpty && _mapController != null) {
        double minLat = pointsItineraire.first.latitude;
        double minLng = pointsItineraire.first.longitude;
        double maxLat = minLat;
        double maxLng = minLng;
        for (var p in pointsItineraire) {
           if (p.latitude < minLat) minLat = p.latitude;
           if (p.longitude < minLng) minLng = p.longitude;
           if (p.latitude > maxLat) maxLat = p.latitude;
           if (p.longitude > maxLng) maxLng = p.longitude;
        }
        _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
           LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
           left: 50, right: 50, top: 50, bottom: 200 // Padding pour la vue UI
        ));
    }
  }

  // --- FONCTION RECHERCHE (LOOK WAZE) ---
  Future<void> _rechercherDestination(String texte) async {
    if (texte.trim().isEmpty) return;
    final url = Uri.parse(
      'https://photon.komoot.io/api/?q=${Uri.encodeComponent(texte)}&lat=${maPosition.latitude}&lon=${maPosition.longitude}&limit=1&lang=fr',
    );
    try {
      final reponse = await http.get(
        url,
        headers: {'User-Agent': 'gpex_app/1.0', 'Accept': 'application/json'},
      );
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        if (data['features'].isNotEmpty) {
          _selectionnerSuggestion(data['features'][0]);
        }
      }
    } catch (e) {
      debugPrint('Erreur recherche: $e');
    }
  }

  // --- DECODEUR POLYLINE VALHALLA (Précision 6 décimales) ---
  List<LatLng> _decodeValhallaPolyline(String encoded) {
    List<LatLng> polyline = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      final pLat = lat / 1E6;
      final pLng = lng / 1E6;
      polyline.add(LatLng(pLat, pLng));
    }
    return polyline;
  }

  // --- APPEL API TOMTOM TRAFIC ASYNCHRONE CORRIGÉ ---
  Future<void> _fetchTomTomTraffic(LatLng depart, LatLng arrivee) async {
    final url = Uri.parse(
        'https://api.tomtom.com/routing/1/calculateRoute/${depart.latitude},${depart.longitude}:${arrivee.latitude},${arrivee.longitude}/json?key=$tomtomApiKey&sectionType=traffic&traffic=true');
    
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final routes = data['routes'];
        if (routes == null || routes.isEmpty) return;
        
        final route = routes[0];
        final sections = route['sections'] as List?;
        final legs = route['legs'] as List?;
        if (sections == null || legs == null || legs.isEmpty) return;
        
        final pointsTomTom = legs[0]['points'] as List;
        List<TrafficSegment> newSegments = [];
        int lastValhallaMappedIndex = 0;

        for (var sec in sections) {
          if (sec['sectionType'] == 'TRAFFIC') {
            int startIdxTT = sec['startPointIndex'];
            int endIdxTT = sec['endPointIndex'];
            int magnitude = sec['magnitudeOfDelay'] ?? 0;
            
            // Déterminer la couleur
            Color trafficColor = const Color(0xFF007AFF); // Bleu
            if (magnitude >= 3) {
              trafficColor = const Color(0xFFFF3B30); // Rouge vif
            } else if (magnitude >= 1) {
              trafficColor = const Color(0xFFFF9500); // Orange
            }

            if (startIdxTT < pointsTomTom.length && endIdxTT < pointsTomTom.length) {
              double startLat = pointsTomTom[startIdxTT]['latitude'];
              double startLon = pointsTomTom[startIdxTT]['longitude'];
              double endLat = pointsTomTom[endIdxTT]['latitude'];
              double endLon = pointsTomTom[endIdxTT]['longitude'];

              // Recherche ultra-rapide sans limite de 500 points (Pythagore)
              int valhallaStart = lastValhallaMappedIndex;
              double bestDistStart = double.infinity;
              for(int i = lastValhallaMappedIndex; i < pointsItineraire.length; i++) {
                double dLat = startLat - pointsItineraire[i].latitude;
                double dLon = startLon - pointsItineraire[i].longitude;
                double distSq = (dLat * dLat) + (dLon * dLon);
                if (distSq < bestDistStart) { bestDistStart = distSq; valhallaStart = i; }
              }

              int valhallaEnd = valhallaStart;
              double bestDistEnd = double.infinity;
              for(int i = valhallaStart; i < pointsItineraire.length; i++) {
                double dLat = endLat - pointsItineraire[i].latitude;
                double dLon = endLon - pointsItineraire[i].longitude;
                double distSq = (dLat * dLat) + (dLon * dLon);
                if (distSq < bestDistEnd) { bestDistEnd = distSq; valhallaEnd = i; }
              }
              
              // Création propre des segments
              if (valhallaStart > lastValhallaMappedIndex) {
                newSegments.add(TrafficSegment(lastValhallaMappedIndex, valhallaStart, const Color(0xFF007AFF)));
              }
              if (valhallaEnd > valhallaStart) {
                newSegments.add(TrafficSegment(valhallaStart, valhallaEnd, trafficColor));
                lastValhallaMappedIndex = valhallaEnd;
              }
            }
          }
        }

        // Remplir la toute fin de la route en Bleu s'il reste des points
        if (lastValhallaMappedIndex < pointsItineraire.length - 1) {
          newSegments.add(TrafficSegment(lastValhallaMappedIndex, pointsItineraire.length - 1, const Color(0xFF007AFF)));
        }

        if (mounted) {
          setState(() {
            segmentsTrafic = newSegments;
          });
          _updateRouteGeoJson();
        }
      }
    } catch (e) {
      debugPrint("Erreur TomTom Trafic: $e");
    }
  }

  // --- FONCTION VALHALLA (L'ITINÉRAIRE) ---
  Future<void> calculerRoute(
    LatLng depart,
    LatLng arrivee,
    String costing,
  ) async {
    setState(() {
      segmentsTrafic = [];
    });


    final url = Uri.parse('https://valhalla.zeusmos.fr/route');
    final corps = json.encode({
      "locations": [
        {"lat": depart.latitude, "lon": depart.longitude},
        {"lat": arrivee.latitude, "lon": arrivee.longitude},
      ],
      "costing": costing,
      "units": "kilometers",
      "directions_options": {"language": "fr-FR"}
    });

    try {
      final reponse = await http.post(url, body: corps);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final shape = data['trip']['legs'][0]['shape'];

        final summary = data['trip']['summary'];
        final length = summary['length']; 
        final timeFormatter = summary['time']; 

        final hours = timeFormatter ~/ 3600;
        final mins = (timeFormatter % 3600) ~/ 60;

        List<LatLng> result = _decodeValhallaPolyline(shape);
        List<int> speeds = List.filled(result.length, 0);
        String prochaineInstruction = "En route"; // <--- NOUVEAU

        try {
          final maneuvers = data['trip']['legs'][0]['maneuvers'] as List;
          
          // --- EXTRACTION DE LA VRAIE INSTRUCTION ---
          if (maneuvers.length > 1) {
            prochaineInstruction = maneuvers[1]['instruction']; 
          } else if (maneuvers.isNotEmpty) {
            prochaineInstruction = maneuvers[0]['instruction'];
          }

          for(var m in maneuvers) {
            int begin = m['begin_shape_index'] ?? 0;
            int end = m['end_shape_index'] ?? 0;
            dynamic spd = m['speed_limit'];
            
            if (spd != null && spd is num && spd > 0) {
               for(int i = begin; i <= end; i++) {
                 if (i < speeds.length) speeds[i] = spd.toInt();
               }
            }
          }
        } catch(e) {
          debugPrint("Erreur Extract: $e");
        }

        setState(() {
          pointsItineraire = result;
          pointsSpeedLimit = speeds;
          instructionActive = prochaineInstruction;
          distanceTextApercu = "${length.toStringAsFixed(1)} km";
          etaTextApercu = hours > 0
              ? "$hours h ${mins.toString().padLeft(2, '0')} min"
              : "$mins min";
        });

        _updateRouteGeoJson();

        if (costing == 'auto') {
          _fetchTomTomTraffic(depart, arrivee);
        }

        if (pointsItineraire.isNotEmpty && !modeNavigation && _mapController != null) {
          double minLat = pointsItineraire.first.latitude;
          double minLng = pointsItineraire.first.longitude;
          double maxLat = minLat;
          double maxLng = minLng;
          for (var p in pointsItineraire) {
             if (p.latitude < minLat) minLat = p.latitude;
             if (p.longitude < minLng) minLng = p.longitude;
             if (p.latitude > maxLat) maxLat = p.latitude;
             if (p.longitude > maxLng) maxLng = p.longitude;
          }
          _mapController!.animateCamera(
             CameraUpdate.newLatLngBounds(
                 LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
                 left: 80, right: 80, top: 80, bottom: 80
             )
          );
        }
      }
    } catch (e) {
      debugPrint("Erreur Valhalla: $e");
    }
  }

  Future<void> chargerRadars() async {
    final url = Uri.parse(
      'https://gps-api.zeusmos.fr/radars?lat=${maPosition.latitude}&lon=${maPosition.longitude}&rayon_km=15',
    );
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        mesRadarsData = data['radars'];
        _majMarkersRadars();
      }
    } catch (e) {
      debugPrint("Erreur API: $e");
    }
  }

  void _majMarkersRadars() async {
    if (mesRadars.isNotEmpty && _mapController != null) {
      await _mapController!.removeCircles(mesRadars);
      mesRadars.clear();
    }
    if (_mapController == null) return;

    List<CircleOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    
    for (var radar in mesRadarsData) {
      options.add(CircleOptions(
        geometry: LatLng(radar['latitude'], radar['longitude']),
        circleColor: "#FF3B30",
        circleRadius: 8.0,
        circleStrokeColor: "#FFFFFF",
        circleStrokeWidth: 2.0,
      ));
      datas.add({'type': 'radar', 'data': radar});
    }
    
    mesRadars = await _mapController!.addCircles(options, datas);
  }

  Future<void> chargerEssence() async {
    final url = Uri.parse(
      'https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/records?limit=100&refine=ville:"Toulouse"',
    );
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        dataEssence = data['results'];
        _majMarkersEssence();
      }
    } catch (e) {
      debugPrint("Erreur API Essence: $e");
    }
  }

  void _majMarkersEssence() async {
    if (markersEssence.isNotEmpty && _mapController != null) {
      await _mapController!.removeCircles(markersEssence);
      markersEssence.clear();
    }
    if (!afficherEssence || _mapController == null) return;

    List<CircleOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    for (var station in dataEssence) {
      options.add(CircleOptions(
        geometry: LatLng(station['geom']['lat'], station['geom']['lon']),
        circleColor: "#FF9500",
        circleRadius: 8.0,
        circleStrokeColor: "#FFFFFF",
        circleStrokeWidth: 2.0,
      ));
      datas.add({'type': 'essence', 'data': station});
    }
    markersEssence = await _mapController!.addCircles(options, datas);
  }

  void _afficherDetailsEssence(dynamic station) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                station['adresse'] ?? 'Station Essence',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              if (station['gazole_prix'] != null)
                Text('Gazole : ${station['gazole_prix']} €'),
              if (station['e10_prix'] != null)
                Text('SP95-E10 : ${station['e10_prix']} €'),
              if (station['sp98_prix'] != null)
                Text('SP98 : ${station['sp98_prix']} €'),
              if (station['e85_prix'] != null)
                Text('E85 : ${station['e85_prix']} €'),
              
              _buildBoutonItineraire(
                LatLng(station['geom']['lat'], station['geom']['lon']), 
                station['adresse'] ?? 'Station Essence'
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> chargerParking() async {
    final url = Uri.parse(
      'https://data.toulouse-metropole.fr/api/explore/v2.1/catalog/datasets/parcs-de-stationnement/records?limit=100',
    );
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        dataParking = data['results'];
        _majMarkersParking();
      }
    } catch (e) {
      debugPrint("Erreur API Parking: $e");
    }
  }

  void _majMarkersParking() async {
    if (markersParking.isNotEmpty && _mapController != null) {
      await _mapController!.removeCircles(markersParking);
      markersParking.clear();
    }
    if (!afficherParking || _mapController == null) return;

    List<CircleOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    for (var parking in dataParking) {
      options.add(CircleOptions(
        geometry: LatLng(parking['ylat'], parking['xlong']),
        circleColor: "#007AFF",
        circleRadius: 8.0,
        circleStrokeColor: "#FFFFFF",
        circleStrokeWidth: 2.0,
      ));
      datas.add({'type': 'parking', 'data': parking});
    }
    markersParking = await _mapController!.addCircles(options, datas);
  }

  void _afficherDetailsParking(dynamic parking) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                parking['nom'] ?? 'Parking',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text('Places totales : ${parking['nb_places']}'),
              Text('Tarif 1h : ${parking['tarif_1h']} €'),
              Text('Tarif 24h : ${parking['tarif_24h']} €'),
              Text('Gestionnaire : ${parking['gestionnaire']}'),
              _buildBoutonItineraire(
                 LatLng(parking['ylat'], parking['xlong']), 
                 parking['nom'] ?? 'Parking'
              ),
            ],
          ),
        );
      },
    );
  }

  // --- RECHARGE ÉLECTRIQUE ---
  Future<void> chargerBornes() async {
    final url = Uri.parse(
      "https://odre.opendatasoft.com/api/explore/v2.1/catalog/datasets/bornes-irve/records?where=within_distance(coordonneesxy, geom'POINT(${maPosition.longitude} ${maPosition.latitude})', 15km)&limit=100",
    );
    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        dataBornes = data['results'];
        _majMarkersBornes();
      }
    } catch (e) {
      debugPrint("Erreur API Bornes: $e");
    }
  }

  void _majMarkersBornes() async {
    if (markersBornes.isNotEmpty && _mapController != null) {
      await _mapController!.removeCircles(markersBornes);
      markersBornes.clear();
    }
    if (!afficherBornes || _mapController == null) return;

    List<CircleOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    for (var borne in dataBornes) {
        final double? lat = borne['consolidated_latitude'] ?? borne['coordonneesxy']?['lat'];
        final double? lon = borne['consolidated_longitude'] ?? borne['coordonneesxy']?['lon'];
        if (lat == null || lon == null) continue;

        options.add(CircleOptions(
            geometry: LatLng(lat, lon),
            circleColor: "#2fbd0cff",
            circleRadius: 8.0,
            circleStrokeColor: "#FFFFFF",
            circleStrokeWidth: 2.0,
        ));
        datas.add({'type': 'borne', 'data': borne});
    }
    markersBornes = await _mapController!.addCircles(options, datas);
  }

  void _afficherDetailsBorne(dynamic borne) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                borne['nom_station'] ?? 'Station de recharge',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.flash_on, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    "Puissance: ${borne['puissance_nominale'] ?? 'N/A'} kW",
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.cable, color: Colors.blueGrey, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Prises: ${borne['type_prise'] ?? 'Non spécifié'}",
                      style: const TextStyle(fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${borne['adresse_station'] ?? ''}, ${borne['consolidated_commune'] ?? ''}",
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  // --- TOURISME (10km) ---
  Future<void> chargerTourisme() async {
    final query =
        '''
      [out:json];
      node(around:10000,${maPosition.latitude},${maPosition.longitude})["tourism"~"museum|attraction|theme_park|gallery|viewpoint"];
      out;
    ''';
    final url = Uri.parse('https://overpass-api.de/api/interpreter');

    try {
      final reponse = await http.post(url, body: {'data': query});
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        dataTourisme = data['elements'];
        _majMarkersTourisme();
      }
    } catch (e) {
      debugPrint("Erreur API Tourisme: $e");
    }
  }

  void _majMarkersTourisme() async {
    if (markersTourisme.isNotEmpty && _mapController != null) {
      await _mapController!.removeCircles(markersTourisme);
      markersTourisme.clear();
    }
    if (!afficherTourisme || _mapController == null) return;

    List<CircleOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    for (var lieu in dataTourisme) {
        final double? lat = lieu['lat'];
        final double? lon = lieu['lon'];
        if (lat == null || lon == null) continue;

        options.add(CircleOptions(
            geometry: LatLng(lat, lon),
            circleColor: "#9610abff",
            circleRadius: 8.0,
            circleStrokeColor: "#FFFFFF",
            circleStrokeWidth: 2.0,
        ));
        datas.add({'type': 'tourisme', 'data': lieu});
    }
    markersTourisme = await _mapController!.addCircles(options, datas);
  }

  void _afficherDetailsTourisme(dynamic lieu) {
    final tags = lieu['tags'] ?? {};
    final nom = tags['name'] ?? 'Lieu touristique';
    final type = tags['tourism'] ?? 'Attraction';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                nom,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.category, color: Colors.purple, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    "Catégorie: $type",
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
              if (tags['website'] != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.language, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tags['website'],
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.blue,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── CARTE 3D MAPLIBRE ──────────────────────────────────────────────
          MaplibreMap(
            styleString: 'https://api.maptiler.com/maps/basic-v2/style.json?key=$mapTilerApiKey',
            initialCameraPosition: CameraPosition(target: maPosition, zoom: 15.0),
            myLocationEnabled: true,
            myLocationTrackingMode: modeNavigation ? MyLocationTrackingMode.TrackingCompass : MyLocationTrackingMode.None,
            compassEnabled: true,
            // Décaler le centre visuel vers le bas de l'écran (Navigation style)
            // Décaler le centre visuel vers le bas de l'écran (Navigation style) géré par un offset visuel
            onMapCreated: (MaplibreMapController controller) {
              _mapController = controller;
              _estCartePrete = true;
              
              _mapController!.onCircleTapped.add((Circle circle) {
                 final properties = circle.data;
                 if (properties != null) {
                    final type = properties['type'];
                    final item = properties['data'];
                    if (type == 'essence') {
                      _afficherDetailsEssence(item);
                    } else if (type == 'parking') {
                      _afficherDetailsParking(item);
                    } else if (type == 'borne') {
                      _afficherDetailsBorne(item);
                    } else if (type == 'tourisme') {
                      _afficherDetailsTourisme(item);
                    }
                 }
              });

              if (gpsActif) {
                _mapController!.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 15.0));
              }
            },
            onStyleLoadedCallback: () {
              // Initialiser la source vide pour la route
              _mapController!.addGeoJsonSource("route-source", {"type": "FeatureCollection", "features": []});
              // Ajouter le layer de lignes par-dessus
              _mapController!.addLineLayer(
                "route-source",
                "route-layer-border",
                LineLayerProperties(
                  lineColor: ["get", "color"],
                  lineWidth: 10.0,
                  lineJoin: "round",
                  lineCap: "round",
                ),
                filter: ["==", "isBorder", true]
              );
              _mapController!.addLineLayer(
                "route-source",
                "route-layer-main",
                LineLayerProperties(
                  lineColor: ["get", "color"],
                  lineWidth: 6.0,
                  lineJoin: "round",
                  lineCap: "round",
                ),
                filter: ["==", "isBorder", false]
              );
              _mapController!.addCircleLayer(
                "route-source",
                "destination-layer",
                CircleLayerProperties(
                  circleColor: "#34C759",
                  circleRadius: 10.0,
                  circleStrokeColor: "#FFFFFF",
                  circleStrokeWidth: 3.0,
                ),
                filter: ["==", "isDestination", true]
              );
              _updateRouteGeoJson(); // Dessiner la route si existante

              chargerRadars();
              if (afficherEssence) chargerEssence();
              if (afficherParking) chargerParking();
              if (afficherBornes) chargerBornes();
              if (afficherTourisme) chargerTourisme();
            },
          ),

          // ── BARRE DE RECHERCHE + CHIPS (Cachés si mode navigation) ────────
          if (!modeNavigation)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Ligne : barre de recherche + bouton localisation
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1C1E),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocus,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Où allez-vous ?',
                                  hintStyle: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    fontSize: 15,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search,
                                    color: Colors.white.withValues(alpha: 0.5),
                                    size: 22,
                                  ),
                                  suffixIcon: _searchController.text.isNotEmpty
                                      ? GestureDetector(
                                          onTap: () {
                                            _searchController.clear();
                                            _searchFocus.unfocus();
                                            setState(() {
                                              _suggestions = [];
                                              destination = null;
                                              pointsItineraire = [];
                                              modeNavigation = false;
                                              modeApercuTrajet = false;
                                            });
                                          },
                                          child: Icon(
                                            Icons.close,
                                            color: Colors.white.withValues(
                                              alpha: 0.5,
                                            ),
                                            size: 20,
                                          ),
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  isDense: true,
                                ),
                                onChanged: (v) {
                                  debugPrint(
                                    '⌨️ onChanged TextField: "$v" (Focus: ${_searchFocus.hasFocus})',
                                  );
                                  _rechercherSuggestions(v);
                                },
                                onSubmitted: (v) {
                                  debugPrint('✅ onSubmitted TextField: "$v"');
                                  _rechercherDestination(v);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () => _mapController?.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 15.0)),
                            child: Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1C1E),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Icon(
                                Icons.my_location,
                                color: Colors.blueAccent.withValues(alpha: 0.9),
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Chips
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _filterChip(
                              label: 'Stations',
                              activeColor: Colors.orange,
                              iconWidget: Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.local_gas_station,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              active: afficherEssence,
                              onTap: () {
                                setState(() {
                                  afficherEssence = !afficherEssence;
                                  if (afficherEssence && dataEssence.isEmpty) {
                                    chargerEssence();
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            _filterChip(
                              label: 'Parkings',
                              activeColor: const Color(0xFF2979FF),
                              iconWidget: Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF2979FF),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.local_parking,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              active: afficherParking,
                              onTap: () {
                                setState(() {
                                  afficherParking = !afficherParking;
                                  if (afficherParking && dataParking.isEmpty) {
                                    chargerParking();
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            _filterChip(
                              label: 'Recharge',
                              activeColor: Colors.green.shade700,
                              iconWidget: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Colors.green.shade700,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.ev_station,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              active: afficherBornes,
                              onTap: () {
                                setState(() {
                                  afficherBornes = !afficherBornes;
                                  if (afficherBornes && dataBornes.isEmpty) {
                                    chargerBornes();
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            _filterChip(
                              label: 'Tourisme',
                              activeColor: Colors.purple.shade500,
                              iconWidget: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Colors.purple.shade500,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.camera_alt,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                              active: afficherTourisme,
                              onTap: () {
                                setState(() {
                                  afficherTourisme = !afficherTourisme;
                                  if (afficherTourisme &&
                                      dataTourisme.isEmpty) {
                                    chargerTourisme();
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── SUGGESTIONS (Positioned séparé pour éviter le clipping) ───────
          if (!modeNavigation &&
              _searchFocus.hasFocus &&
              _suggestions.isNotEmpty)
            Positioned(
              top: 80,
              left: 12,
              right: 74,
              child: SafeArea(
                bottom: false,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 280),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.07),
                      ),
                      itemBuilder: (context, index) {
                        final feature = _suggestions[index];
                        final props = feature['properties'];
                        final nom = props['name'] ?? '';
                        final ville = props['city'] ?? props['state'] ?? '';
                        final pays = props['country'] ?? '';
                        final sousTitre = [
                          ville,
                          pays,
                        ].where((s) => s.isNotEmpty).join(', ');
                        return InkWell(
                          onTap: () => _selectionnerSuggestion(feature),
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  color: Colors.blueAccent.withValues(
                                    alpha: 0.8,
                                  ),
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        nom,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (sousTitre.isNotEmpty)
                                        Text(
                                          sousTitre,
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.45,
                                            ),
                                            fontSize: 12,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

          // ── 1. PANNEAU DIRECTIONS HAUT ────────────
          if (modeNavigation)
            Positioned(
              top: 50,
              left: 16,
              right: 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 15, offset: const Offset(0, 8)),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.turn_right, color: Colors.white, size: 32),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                "Prochaine direction", // Texte générique ou distance au virage (à coder plus tard)
                                style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                instructionActive, // <--- LA VRAIE INSTRUCTION VALHALLA
                                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── 2. ALERTE RADAR PROXIMITÉ ────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            // S'il y a un radar : On le met à top: 150 s'il y a le bandeau de nav, sinon top: 60
            top: radarProcheDistance != double.infinity 
                  ? (modeNavigation ? 160 : 60) 
                  : -120, 
            left: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF3B30), Color(0xFFFF453A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.redAccent.withValues(alpha: 0.5), blurRadius: 15, offset: const Offset(0, 6)),
                  ],
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Zone de Danger",
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            radarProcheDistance != double.infinity 
                                ? "Radar à ${radarProcheDistance.round()} m" 
                                : "",
                            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── COMPTEUR DE VITESSE (Style Waze) ────────────
          if (modeNavigation)
            Positioned(
              bottom: 160, // Juste au-dessus du panneau ETA
              left: 16,
              child: Row(
                children: [
                  // Compteur
                  Container(
                    width: 65,
                    height: 65,
                    decoration: BoxDecoration(
                      color: (vitesseLimiteCible > 0 && vitesseKmh > vitesseLimiteCible + 5) 
                          ? Colors.redAccent.shade100 
                          : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                      border: Border.all(
                        color: (vitesseLimiteCible > 0 && vitesseKmh > vitesseLimiteCible + 5)
                            ? Colors.redAccent.shade700
                            : Colors.grey.shade300, 
                        width: 3
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            vitesseKmh.round().toString(),
                            style: TextStyle(
                              color: (vitesseLimiteCible > 0 && vitesseKmh > vitesseLimiteCible + 5) 
                                  ? Colors.red.shade900 
                                  : Colors.black,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                          Text(
                            "km/h",
                            style: TextStyle(
                              color: (vitesseLimiteCible > 0 && vitesseKmh > vitesseLimiteCible + 5) 
                                  ? Colors.red.shade800 
                                  : Colors.black54,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Panneau Speed Limit Européen
                  if (vitesseLimiteCible > 0)
                    Container(
                      width: 55,
                      height: 55,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.redAccent.shade700, width: 6),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          vitesseLimiteCible.round().toString(),
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // ── PANNEAU TRAJET BAS (Style Waze ETA) ────────────
          if (modeNavigation && destination != null)
            Positioned(
              bottom: 30,
              left: 16,
              right: 16,
              child: Builder(
                builder: (ctx) {
                  // On utilise directement les résultats de Valhalla stockés dans les variables "Aperçu"
                  // qui sont mises à jour par calculerRoute dans la boucle Geolocator.
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              etaTextApercu.isNotEmpty
                                  ? etaTextApercu
                                  : "Calcul...",
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              distanceTextApercu.isNotEmpty
                                  ? distanceTextApercu
                                  : "0 km",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              modeNavigation = false;
                              modeApercuTrajet = false;
                              destination = null;
                              pointsItineraire = [];
                              _searchController.clear();
                            });
                            _updateRouteGeoJson();
                            _mapController?.animateCamera(
                              CameraUpdate.newCameraPosition(
                                CameraPosition(
                                  target: maPosition, 
                                  zoom: 15.0, 
                                  tilt: 0.0,
                                  bearing: 0.0
                                )
                              )
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.shade700,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: const Text(
                              "Quitter",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

          // ── PANNEAU APERÇU DU TRAJET (Google Maps Style) ────────────
          if (modeApercuTrajet && !modeNavigation)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.only(
                  top: 20,
                  left: 24,
                  right: 24,
                  bottom: 40,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 20,
                      offset: Offset(0, -5),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pilule de drag
                    Container(
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade600,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Sélecteur de mode de transport
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _boutonTransport(Icons.directions_car, 'auto'),
                        _boutonTransport(Icons.pedal_bike, 'bicycle'),
                        _boutonTransport(Icons.directions_walk, 'pedestrian'),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Informations ETA & Distance
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              etaTextApercu.isNotEmpty
                                  ? etaTextApercu
                                  : "Calcul...",
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              distanceTextApercu.isNotEmpty
                                  ? "($distanceTextApercu)"
                                  : "",
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        // Bouton Démarrer
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                            elevation: 8,
                          ),
                          icon: const Icon(Icons.navigation, size: 20),
                          label: const Text(
                            "Démarrer",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onPressed: () {
                            setState(() {
                              modeApercuTrajet = false;
                              modeNavigation = true;
                            });
                            // Zoom et rotation immersifs
                            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 18.0));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Widget pour les icônes de transport
  Widget _boutonTransport(IconData icone, String mode) {
    bool isSelected = (transportMode == mode);
    return GestureDetector(
      onTap: () {
        if (!isSelected) {
          setState(() {
            transportMode = mode;
            etaTextApercu = "Calcul...";
            distanceTextApercu = "";
          });
          if (destination != null) {
            calculerRoute(maPosition, destination!, transportMode);
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent.shade700.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.blueAccent.shade700 : Colors.transparent,
            width: 2,
          ),
        ),
        child: Icon(
          icone,
          color: isSelected ? Colors.blueAccent.shade400 : Colors.white54,
          size: 28,
        ),
      ),
    );
  }

  /// Chip de filtre style Waze (icône ronde + label)
  Widget _filterChip({
    required String label,
    required Widget iconWidget,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? activeColor : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: active ? activeColor : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconWidget,
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
