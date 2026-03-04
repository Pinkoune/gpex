import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui'; // Pour le BackdropFilter (Glassmorphism)
import 'package:geolocator/geolocator.dart';
import 'dart:math';

const String tomtomApiKey = "gCm05RjVrOc3Ew1WlUgn9zrbjImAKW9n";

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

class _CarteScreenState extends State<CarteScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  String instructionActive = "Suivez l'itinéraire";
  bool _estCartePrete = false; // Flag pour s'assurer que la carte est prête
  LatLng maPosition = const LatLng(43.6046, 1.4442);
  List<Marker> mesRadars = [];
  bool gpsActif = false;
  // --- NOUVELLES VARIABLES ---
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée
  bool modeNavigation = false; // Mode GPS Waze-like activé
  double vitesseKmh = 0.0; // Vitesse du véhicule
  double vitesseLimiteCible = 0.0; // Vitesse réglementée max
  List<int> pointsSpeedLimit = []; // Limitations par Shape Index
  List<TrafficSegment> segmentsTrafic = []; // Segments de couleurs calculés

  // --- ANIMATIONS MAP ---
  AnimationController? _animController;
  Animation<double>? _zoomAnim;
  Animation<double>? _rotAnim;
  Animation<LatLng>? _centerAnim;
  
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
  List<Marker> markersEssence = [];
  List<Marker> markersParking = [];
  List<Marker> markersBornes = [];
  List<Marker> markersTourisme = [];
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
    _animController?.dispose();
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
          // Calcul Zoom Dynamique : à 0-20km/h => zoom 18. à >80km/h => zoom 16
          double targetZoom = 18.0;
          if (vitesseKmh > 80) {
            targetZoom = 15.5;
          } else if (vitesseKmh > 40) {
            targetZoom = 16.5;
          }
          
          double targetRot = position.heading > 0 ? (360 - position.heading) : 0.0;

          
          // Aligner virtuellement le véhicule en bas. 
          // (Décaler le LatLng cible vers le HAUT pour compenser)
          // Approximation basique proportionnelle au zoom.
          double offsetLat = (0.0005 * (18.0 / targetZoom)) * cos(position.heading * pi / 180);
          double offsetLng = (0.0005 * (18.0 / targetZoom)) * sin(position.heading * pi / 180);
          LatLng targetCenter = LatLng(maPosition.latitude + offsetLat, maPosition.longitude + offsetLng);

          _animerCarte(targetCenter, targetZoom, targetRot);
        } else {
          // _mapController.move(maPosition, 15.0); // Simple centrage sans rotation fixe
        }
      }
      chargerRadars();
      
      // Radar Alert Logic
      double minDistRadar = double.infinity;
      if (modeNavigation && gpsActif && mesRadars.isNotEmpty) {
        for (var marker in mesRadars) {
          double dist = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              marker.point.latitude, marker.point.longitude);
          
          if (dist <= 800) { // Afficher jusqu'à 800m
             double bearing = Geolocator.bearingBetween(
                position.latitude, position.longitude,
                marker.point.latitude, marker.point.longitude);
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
          _mapController.move(maPosition, 15.0);
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
          _mapController.move(maPosition, 15.0);
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

  void _animerCarte(LatLng cible, double destZoom, double destRot) {
    _animController?.dispose();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000), // Smooth 1 sec
    );

    final LatLng startX = _mapController.camera.center;
    final double startZ = _mapController.camera.zoom;
    final double startR = _mapController.camera.rotation;

    // Normalisation Rotation target to nearest 360 loop to avoid spin-around
    double shortRot = destRot;
    if ((destRot - startR).abs() > 180) {
      if (destRot > startR) {
        shortRot -= 360;
      } else {
        shortRot += 360;
      }
    }

    _centerAnim = LatLngTween(begin: startX, end: cible).animate(CurvedAnimation(parent: _animController!, curve: Curves.easeOut));
    _zoomAnim = Tween<double>(begin: startZ, end: destZoom).animate(CurvedAnimation(parent: _animController!, curve: Curves.easeOut));
    _rotAnim = Tween<double>(begin: startR, end: shortRot).animate(CurvedAnimation(parent: _animController!, curve: Curves.easeOut));

    _animController!.addListener(() {
      _mapController.move(_centerAnim!.value, _zoomAnim!.value);
      _mapController.rotate(_rotAnim!.value);
    });

    _animController!.forward();
  }

  // --- TRAFFIC REEL (TOMTOM) CORRIGÉ ---
  List<Polyline> _buildTrafficPolylines() {
    if (pointsItineraire.isEmpty) return [];

    List<Polyline> lines = [];

    // 1. Fallback si TomTom ne répond pas ou est vide
    if (segmentsTrafic.isEmpty) {
      lines.add(Polyline(
        points: pointsItineraire,
        color: const Color(0xFF007AFF),
        strokeWidth: 6.0,
        borderStrokeWidth: 2.0,
        borderColor: Colors.white,
        strokeCap: StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      ));
      return lines;
    }

    // 2. S'il y a du trafic, on dessine chaque segment coloré avec sa bordure
    for (var segment in segmentsTrafic) {
      if (segment.startIndex >= 0 && segment.endIndex < pointsItineraire.length && segment.startIndex < segment.endIndex) {
        lines.add(Polyline(
          points: pointsItineraire.sublist(segment.startIndex, segment.endIndex + 1),
          color: segment.color,
          strokeWidth: 6.0,
          borderStrokeWidth: 2.0,
          borderColor: Colors.white,
          strokeJoin: StrokeJoin.round,
          strokeCap: StrokeCap.round,
        ));
      }
    }

    return lines;
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

        if (costing == 'auto') {
          _fetchTomTomTraffic(depart, arrivee);
        }

        if (pointsItineraire.isNotEmpty && !modeNavigation) {
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(pointsItineraire),
              padding: const EdgeInsets.all(80),
            ),
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
        final List radarsAPI = data['radars'];
        setState(() {
          mesRadars = radarsAPI.map((radar) {
            return Marker(
              point: LatLng(radar['latitude'], radar['longitude']),
              width: 45,
              height: 45,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.redAccent.shade700, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.redAccent.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.camera_alt,
                    color: Colors.black87,
                    size: 22,
                  ),
                ),
              ),
            );
          }).toList();
        });
      }
    } catch (e) {
      debugPrint("Erreur API: $e");
    }
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

  void _majMarkersEssence() {
    double minPrix = double.infinity;
    for (var station in dataEssence) {
      double? prix = station['gazole_prix'] ?? station['e10_prix'];
      if (prix != null && prix < minPrix) {
        minPrix = prix;
      }
    }

    setState(() {
      markersEssence = dataEssence.map((station) {
        double? prix = station['gazole_prix'] ?? station['e10_prix'];
        bool estMoinsChere = prix != null && prix == minPrix;
        String textePrix = prix != null
            ? "${prix.toStringAsFixed(3)} €"
            : "N/A";

        return Marker(
          point: LatLng(station['geom']['lat'], station['geom']['lon']),
          width: 70,
          height: 30,
          child: GestureDetector(
            onTap: () => _afficherDetailsEssence(station),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: estMoinsChere ? Colors.green : Colors.orange,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                textePrix,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }).toList();
    });
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

  void _majMarkersParking() {
    double minTarif = double.infinity;
    for (var parking in dataParking) {
      double? tarif = parking['tarif_1h']; // On compare le tarif 1h
      if (tarif != null && tarif < minTarif) {
        minTarif = tarif;
      }
    }

    setState(() {
      markersParking = dataParking.map((parking) {
        double? tarif = parking['tarif_1h'];
        bool estMoinsCher = tarif != null && tarif == minTarif;
        String textePrix = tarif != null
            ? "${tarif.toStringAsFixed(2)} €"
            : "N/A";

        return Marker(
          point: LatLng(parking['ylat'], parking['xlong']),
          width: 70,
          height: 35,
          child: GestureDetector(
            onTap: () => _afficherDetailsParking(parking),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: estMoinsCher ? Colors.green : Colors.blue,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    textePrix,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    "${parking['dispo'] ?? '?'} places",
                    style: const TextStyle(color: Colors.white70, fontSize: 9),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList();
    });
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

  void _majMarkersBornes() {
    setState(() {
      markersBornes = dataBornes
          .map((borne) {
            // Note: In ODRE API, `coordonneesxy` object has lon/lat keys often mapped correctly or swapped depending on the dataset version.
            // But we actually have `consolidated_latitude` and `consolidated_longitude` which are safer.
            final double? lat =
                borne['consolidated_latitude'] ??
                borne['coordonneesxy']?['lat'];
            final double? lon =
                borne['consolidated_longitude'] ??
                borne['coordonneesxy']?['lon'];

            if (lat == null || lon == null) return null;

            return Marker(
              point: LatLng(lat, lon),
              width: 40,
              height: 40,
              child: GestureDetector(
                onTap: () => _afficherDetailsBorne(borne),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: const Icon(
                    Icons.ev_station,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            );
          })
          .whereType<Marker>()
          .toList();
    });
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

  void _majMarkersTourisme() {
    setState(() {
      markersTourisme = dataTourisme
          .map((lieu) {
            final double? lat = lieu['lat'];
            final double? lon = lieu['lon'];

            if (lat == null || lon == null) return null;

            return Marker(
              point: LatLng(lat, lon),
              width: 40,
              height: 40,
              child: GestureDetector(
                onTap: () => _afficherDetailsTourisme(lieu),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.purple.shade500,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: const Icon(
                    Icons.camera_alt,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            );
          })
          .whereType<Marker>()
          .toList();
    });
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
          // ── CARTE ──────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: maPosition,
              initialZoom: 15.0,
              onMapReady: () {
                _estCartePrete = true;
                if (gpsActif) {
                  _mapController.move(maPosition, 15.0);
                }
              },
            ),
            children: [
              TileLayer(
                // urlTemplate: 'https://tileserver.zeusmos.fr/styles/osm-liberty/{z}/{x}/{y}.png',
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.jeremy.gps',
                keepBuffer: 5,
                panBuffer: 2,
              ),
              PolylineLayer(
                polylines: _buildTrafficPolylines(),
              ),
              MarkerLayer(markers: mesRadars),
              if (afficherEssence) MarkerLayer(markers: markersEssence),
              if (afficherParking) MarkerLayer(markers: markersParking),
              if (afficherBornes) MarkerLayer(markers: markersBornes),
              if (afficherTourisme) MarkerLayer(markers: markersTourisme),
              MarkerLayer(
                markers: [
                  Marker(
                    point: maPosition,
                    width: 45,
                    height: 45,
                    child: modeNavigation
                        ? _buildCarMarker()
                        : _buildBlueDotMarker(),
                  ),
                  if (destination != null)
                    Marker(
                      point: destination!,
                      width: 36,
                      height: 36,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.green,
                        size: 36,
                      ),
                    ),
                ],
              ),
            ],
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
                            onTap: () => _mapController.move(maPosition, 15.0),
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
                            _mapController.move(maPosition, 15.0);
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
                            _mapController.move(maPosition, 18.0);
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

  // ── CUSTOM MARKERS ────────────────────────────────────────────────────────

  // Marqueur Position Google Maps (Cercle bleu avec bordure blanche et ombre)
  Widget _buildBlueDotMarker() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blueAccent,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.blueAccent.withValues(alpha: 0.4),
            blurRadius: 10,
            spreadRadius: 4,
          ),
          const BoxShadow(
            color: Colors.black26,
            blurRadius: 5,
            offset: Offset(0, 3),
          ),
        ],
      ),
      margin: const EdgeInsets.all(12),
    );
  }

  // Marqueur Voiture de Navigation (Style Waze / 3D)
  Widget _buildCarMarker() {
    IconData iconeCurseur = Icons.directions_car;
    
    if (transportMode == 'bicycle') {
      iconeCurseur = Icons.pedal_bike;
    } else if (transportMode == 'pedestrian') {
      iconeCurseur = Icons.directions_walk;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.blueAccent.shade700, width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      child: Center(
        child: Icon(iconeCurseur, color: Colors.black87, size: 24),
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
