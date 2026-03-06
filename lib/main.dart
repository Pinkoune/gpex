import 'package:flutter/material.dart';
import 'package:maplibre_gl/mapbox_gl.dart'; // Remplace flutter_map et latlong2
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui'; // Pour le BackdropFilter (Glassmorphism)
import 'package:geolocator/geolocator.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'dart:async';

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
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
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
  int indexRouteActuel = 0;
  bool _enCoursDeRecalcul = false;
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée
  bool modeNavigation = false; // Mode GPS Waze-like activé
  double vitesseKmh = 0.0; // Vitesse du véhicule
  double vitesseLimiteCible = 0.0; // Vitesse réglementée max
  List<int> pointsSpeedLimit = []; // Limitations par Shape Index
  List<TrafficSegment> segmentsTrafic = []; // Segments de couleurs calculés

  // --- ONDE ---
  bool _isOndeActive = false;
  Timer? _timerOnde;
  double _ondeRadius = 0.0;
  double _ondeOpacity = 1.0;
  LatLng? _radarCibleOnde;

  double radarProcheDistance = double.infinity; // Radar info

  // Aperçu du trajet (Google Maps style)
  bool modeApercuTrajet = false;
  bool _estEnCoursDeZoom = false;
  String transportMode = 'auto'; // 'auto', 'bicycle', 'pedestrian'
  String distanceTextApercu = "";
  String etaTextApercu = "";

  bool afficherEssence = false;
  bool afficherParking = false;
  bool afficherBornes = false;
  bool afficherTourisme = false;
  List<Symbol> markersEssence = [];
  List<Symbol> markersParking = [];
  List<Circle> markersBornes = [];
  List<Circle> markersTourisme = [];
  List<Symbol> mesRadars = [];
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

  // --- TOOL : CRÉATION DE L'ARRIVÉE TYPE WAZE ---
  Future<Uint8List?> _createCustomMarketBitmap(String assetPath) async {
    try {
      // 1. Charger l'image brute (140x140 pour le zoom)
      final ByteData data = await rootBundle.load(assetPath);
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 140, 
        targetHeight: 140, 
      );
      final ui.FrameInfo fi = await codec.getNextFrame();
      final ui.Image image = fi.image;

      // 2. Préparer le canvas (hauteur réduite à 120 au lieu de 130)
      const double canvasWidth = 100.0;
      const double canvasHeight = 120.0; 
      final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(pictureRecorder);

      // Centre et rayon de la bulle blanche globale
      const Offset center = Offset(canvasWidth / 2, 50.0);
      const double radius = 46.0;

      // Création du cercle principal
      final Path bullePath = Path()
        ..addOval(Rect.fromCircle(center: center, radius: radius));
      
      // Création de la flèche vers le bas (PLUS PETITE)
      final Path flechePath = Path()
        ..moveTo(canvasWidth / 2 - 12, 90.0) // Base moins large (12 au lieu de 16)
        ..lineTo(canvasWidth / 2, 110.0)     // Pointe moins basse (110 au lieu de 125)
        ..lineTo(canvasWidth / 2 + 12, 90.0) // Base moins large
        ..close();

      // Fusionner le cercle et la flèche
      final Path pathFinal = Path.combine(PathOperation.union, bullePath, flechePath);

      // 3. Dessiner l'ombre
      final Paint shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
      canvas.drawPath(pathFinal, shadowPaint);

      // 4. Dessiner le fond blanc
      final Paint borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawPath(pathFinal, borderPaint);

      // 5. Découper la zone centrale
      final Path clipPath = Path()
        ..addOval(Rect.fromCircle(center: center, radius: 40.0)); 
      
      canvas.save();
      canvas.clipPath(clipPath);

      // Dessiner l'image avec l'effet de zoom
      paintImage(
        canvas: canvas,
        rect: Rect.fromCenter(center: center, width: 140.0, height: 140.0), 
        image: image,
        fit: BoxFit.cover,
      );
      
      canvas.restore(); 

      // 6. Exporter l'image
      final ui.Image finalImage = await pictureRecorder.endRecording().toImage(
        canvasWidth.toInt(),
        canvasHeight.toInt(),
      );
      final ByteData? byteData = await finalImage.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint("Erreur Canvas Marker: $e");
      return null;
    }
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
        if (!modeNavigation) {
           // Sans anim pour coller au basique de la 2D ? 
           //_mapController?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: maPosition, tilt: 0.0, bearing: 0.0)));
        }
      }
      chargerRadars();
      
      // Radar Alert Logic
      double minDistRadar = double.infinity;
      LatLng? radarLePlusProche;

      if (modeNavigation && gpsActif && mesRadarsData.isNotEmpty) {
        for (var radar in mesRadarsData) {
              double dist = Geolocator.distanceBetween(
                  position.latitude, position.longitude,
                  radar['latitude'], radar['longitude']);
              
              if (dist <= 300) { // Radar dans le périmètre
                 double bearing = Geolocator.bearingBetween(
                    position.latitude, position.longitude,
                    radar['latitude'], radar['longitude']);
             double angleDiff = (bearing - position.heading).abs();
             if (angleDiff > 180) angleDiff = 360 - angleDiff;
             
                 // Si le radar est bien DEVANt nous (angle de 60°) ET qu'il est sur notre route (valable à 35m près)
                 if (angleDiff <= 60 && _isRadarOnRoute(radar['latitude'], radar['longitude'])) {
                     if (dist < minDistRadar) {
                       minDistRadar = dist;
                       radarLePlusProche = LatLng(radar['latitude'], radar['longitude']);
                     }
                 }
          }
        }
      }

      // Gestion de l'état UI et de l'onde
      setState(() {
        radarProcheDistance = minDistRadar;
      });

      if (radarLePlusProche != null) {
        // Déclenche l'onde sur le radar ciblé
        _gererOndeRadar(radarLePlusProche);
      } else {
        // Coupe l'onde si aucun radar n'est devant nous
        _arreterOndeRadar();
      }

      if (destination != null && pointsItineraire.isNotEmpty && modeNavigation && !_enCoursDeRecalcul) {
        // --- REAL TIME ETA / RECALCULATION ---
        double minDistanceToRoute = double.infinity;
        int minIndex = -1;

        // 1. CORRECTION : On cherche le point le plus proche sur le tracé environnant (On s'autorise à regarder 1 point en arrière pour compenser le drift)
        int startCheck = indexRouteActuel > 0 ? indexRouteActuel - 1 : 0;
        int endCheck = (indexRouteActuel + 10 < pointsItineraire.length) ? indexRouteActuel + 10 : pointsItineraire.length - 1;
        
        for (int i = startCheck; i < endCheck; i++) {
          double dist = _distanceToSegment(
              position.latitude, position.longitude,
              pointsItineraire[i].latitude, pointsItineraire[i].longitude,
              pointsItineraire[i+1].latitude, pointsItineraire[i+1].longitude);
          if (dist < minDistanceToRoute) {
            minDistanceToRoute = dist;
            minIndex = i; // On prend le point de départ du segment
          }
        }
        
        // Gérer le dernier point (si on est pile à l'arrivée)
        if (pointsItineraire.isNotEmpty && endCheck == pointsItineraire.length - 1) {
            double distLast = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              pointsItineraire.last.latitude, pointsItineraire.last.longitude);
            if (distLast < minDistanceToRoute) {
              minDistanceToRoute = distLast;
              minIndex = pointsItineraire.length - 1;
            }
        }

        // 2. CORRECTION : Tolérance assouplie à 75m pour éviter les recalculs fantômes dans les virages
        if (minDistanceToRoute > 75) { 
             debugPrint("🚩 Déviation détectée ($minDistanceToRoute m). Recalcul de l'itinéraire !");
             
             setState(() {
               _enCoursDeRecalcul = true; // On bloque les futurs appels
               etaTextApercu = "Recalcul...";
             });

             // On relance le calcul de la route depuis la position actuelle
             calculerRoute(maPosition, destination!, transportMode).then((_) {
               setState(() {
                 _enCoursDeRecalcul = false; // On débloque une fois terminé
               });
             });
             
        } else if (minIndex != -1) {
            // --- Assombrir la route au passage ---
            if (minIndex > indexRouteActuel) {
                indexRouteActuel = minIndex;
                _updateRouteGeoJson(); // On redessine la ligne pour la griser !
            }

            // Update Speed Limit Target
            double newLimit = 0.0;
            if (minIndex < pointsSpeedLimit.length) {
              newLimit = pointsSpeedLimit[minIndex].toDouble();
            }

            // Distance restante approximative en cumulant les segments suivants
            double distLeftMeters = 0;
            // Commencer depuis minIndex (ma position projetée actuelle)
            for (int i = minIndex; i < pointsItineraire.length - 1; i++) {
                distLeftMeters += Geolocator.distanceBetween(
                     pointsItineraire[i].latitude, pointsItineraire[i].longitude,
                     pointsItineraire[i+1].latitude, pointsItineraire[i+1].longitude,
                );
            }
            // Enlever la distance déjà parcourue sur le segment actuel
            double distToSegmentEnd = Geolocator.distanceBetween(
                position.latitude, position.longitude,
                pointsItineraire[minIndex+1].latitude, pointsItineraire[minIndex+1].longitude,
            );
            double fullSegmentDist = Geolocator.distanceBetween(
                pointsItineraire[minIndex].latitude, pointsItineraire[minIndex].longitude,
                pointsItineraire[minIndex+1].latitude, pointsItineraire[minIndex+1].longitude,
            );
            distLeftMeters -= (fullSegmentDist - distToSegmentEnd).clamp(0.0, double.infinity);
            
            // ETA dynamique basé sur la Vitesse Temps Réel ou Moyenne Standard
            double speedMs = vitesseKmh > 0 ? position.speed : 13.8; 
            if(speedMs < 5.0 && transportMode == 'auto') speedMs = 13.8; 
            
            int secondsLeft = (distLeftMeters / speedMs).round();
            int hours = secondsLeft ~/ 3600;
            int mins = (secondsLeft % 3600) ~/ 60;

            String newEta = hours > 0 ? "$hours h ${mins.toString().padLeft(2, '0')} min" : "$mins min";
            String newDist = distLeftMeters > 1000 
                ? "${(distLeftMeters / 1000).toStringAsFixed(1)} km" 
                : "${distLeftMeters.round()} m";

            setState(() {
              etaTextApercu = newEta; // Forcer la mise à jour à chaque tic GPS
              distanceTextApercu = newDist; // Update Panel textuel
              vitesseLimiteCible = newLimit; // Update interface Vitesse Max
            });
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

  Future<Uint8List> _creerBulleTexte(String texte, Color couleurFond) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = couleurFond;
    const double radius = 15.0;

    // 1. Préparer le texte
    final TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: texte,
      style: const TextStyle(
        fontSize: 22.0, 
        color: Colors.white, 
        fontWeight: FontWeight.bold,
      ),
    );
    textPainter.layout();

    // 2. Calculer la taille de la bulle en fonction du texte
    final double width = textPainter.width + 24; // Padding horizontal
    final double height = textPainter.height + 16; // Padding vertical

    // 3. Dessiner le rectangle arrondi (la bulle)
    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromLTRB(0.0, 0.0, width, height),
      const Radius.circular(radius),
    );
    canvas.drawRRect(rrect, paint);

    // 4. Dessiner la petite flèche/pointe en bas de la bulle
    final Path path = Path();
    path.moveTo(width / 2 - 8, height);
    path.lineTo(width / 2, height + 10);
    path.lineTo(width / 2 + 8, height);
    path.close();
    canvas.drawPath(path, paint);

    // 5. Placer le texte au centre de la bulle
    textPainter.paint(canvas, const Offset(12.0, 8.0));

    // 6. Convertir le tout en image binaire
    final ui.Image image = await pictureRecorder.endRecording().toImage(
      width.toInt(),
      (height + 10).toInt(),
    );
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<Uint8List> _creerBulleRadar() async {
    // 1. Charger et redimensionner l'image (90x90)
    final ByteData data = await rootBundle.load('assets/icon-radar.jpg');
    final Uint8List bytes = data.buffer.asUint8List();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: 90, targetHeight: 90);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ui.Image imageRadar = frameInfo.image;

    // 2. Préparer le Canvas
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    
    final Paint paintBulle = Paint()..color = Colors.white; 
    final Paint paintBordure = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0; // Épaisseur du contour

    // 3. Dimensions globales du Canvas
    const double canvasWidth = 170.0;
    const double canvasHeight = 195.0; // 170 pour le rond + 25 pour la flèche
    
    // 4. Centre et rayon du cercle 
    // On réduit le rayon à 82 (au lieu de 85) pour laisser la place à la bordure !
    const Offset center = Offset(canvasWidth / 2, 85.0);
    const double radius = 82.0;

    final Path bullePath = Path();
    bullePath.addOval(Rect.fromCircle(center: center, radius: radius));

    final Path flechePath = Path();
    flechePath.moveTo(canvasWidth / 2 - 24, 155.0); // Base bien à l'intérieur du cercle
    flechePath.lineTo(canvasWidth / 2, 190.0);      // Pointe de la flèche
    flechePath.lineTo(canvasWidth / 2 + 24, 155.0); 
    flechePath.close();

    // Fusion des deux formes
    final Path pathFinal = Path.combine(PathOperation.union, bullePath, flechePath);

    // Dessiner le fond blanc PUIS le contour noir par-dessus
    canvas.drawPath(pathFinal, paintBulle);
    canvas.drawPath(pathFinal, paintBordure);

    // 5. Placer ton icône parfaitement au centre (170 - 90) / 2 = 40
    canvas.drawImage(imageRadar, const Offset(40.0, 40.0), Paint());

    // 6. Convertir le tout en image binaire
    final ui.Image finalImage = await pictureRecorder.endRecording().toImage(
      canvasWidth.toInt(),
      canvasHeight.toInt(),
    );
    final ByteData? finalByteData = await finalImage.toByteData(format: ui.ImageByteFormat.png);
    return finalByteData!.buffer.asUint8List();
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
      "geometry": { "type": "LineString", "coordinates": fullCoords },
      "properties": { "color": "#FFFFFF", "isBorder": true }
    });

    // 2. Partie DÉJÀ PARCOURUE (Gris foncé / Assombri)
    if (indexRouteActuel > 0 && indexRouteActuel < pointsItineraire.length) {
      List<List<double>> coordsParcourus = pointsItineraire
          .sublist(0, indexRouteActuel + 1)
          .map((p) => [p.longitude, p.latitude])
          .toList();
      features.add({
        "type": "Feature",
        "geometry": { "type": "LineString", "coordinates": coordsParcourus },
        "properties": { "color": "#B1D7FF", "isBorder": false } // Couleur passée
      });
    }

    // 3. Partie RESTANTE À PARCOURIR (Trafic ou Bleu)
    if (segmentsTrafic.isEmpty) {
      // Trajet normal bleu (uniquement la partie devant nous)
      if (indexRouteActuel < pointsItineraire.length) {
        List<List<double>> coordsRestants = pointsItineraire
            .sublist(indexRouteActuel)
            .map((p) => [p.longitude, p.latitude])
            .toList();
        features.add({
          "type": "Feature",
          "geometry": { "type": "LineString", "coordinates": coordsRestants },
          "properties": { "color": "#007AFF", "isBorder": false }
        });
      }
    } else {
      // Trajet avec trafic (on ne dessine que ce qui est devant nous)
      for (var segment in segmentsTrafic) {
        if (segment.endIndex > indexRouteActuel) {
          int start = segment.startIndex > indexRouteActuel ? segment.startIndex : indexRouteActuel;
          int end = segment.endIndex;
          
          if (start < end && start < pointsItineraire.length) {
            List<List<double>> segCoords = pointsItineraire
                .sublist(start, end + 1)
                .map((p) => [p.longitude, p.latitude])
                .toList();
            
            String hexColor = '#${(segment.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
            features.add({
              "type": "Feature",
              "geometry": { "type": "LineString", "coordinates": segCoords },
              "properties": { "color": hexColor, "isBorder": false }
            });
          }
        }
      }
    }

    // 4. Point d'arrivée
    if (destination != null && pointsItineraire.isNotEmpty) {
      features.add({
        "type": "Feature",
        "geometry": { "type": "Point", "coordinates": [destination!.longitude, destination!.latitude] },
        "properties": { "isDestination": true, "isBorder": false }
      });
    }

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
        String prochaineInstruction = "En route";

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
          indexRouteActuel = 0;
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

  // --- MATHEMATHIC TOOLS FOR DISTANCE TO SEGMENT ---
  double _distanceToSegment(double pLat, double pLon, double vLat, double vLon, double wLat, double wLon) {
      // Return minimum distance between line segment vw and point p
      double distSquared = (vLat - wLat) * (vLat - wLat) + (vLon - wLon) * (vLon - wLon);
      if (distSquared == 0.0) {
          return Geolocator.distanceBetween(pLat, pLon, vLat, vLon);
      }
      // Consider the line extending the segment, parameterized as v + t (w - v).
      // We find projection of point p onto the line. 
      // It falls where t = [(p-v) . (w-v)] / |w-v|^2
      // We clamp t from [0,1] to handle points outside the segment vw.
      double t = ((pLat - vLat) * (wLat - vLat) + (pLon - vLon) * (wLon - vLon)) / distSquared;
      t = t.clamp(0.0, 1.0);
      
      double projLat = vLat + t * (wLat - vLat);
      double projLon = vLon + t * (wLon - vLon);
      
      return Geolocator.distanceBetween(pLat, pLon, projLat, projLon);
  }

  // --- MATHEMATHIC TOOL : VÉRIFIER SI UN POINT EST SUR LA ROUTE ---
  bool _isRadarOnRoute(double radarLat, double radarLon) {
      if (!modeNavigation || pointsItineraire.isEmpty) return false;

      // On vérifie uniquement les segments restants devant nous (+ une petite sécurité arrière)
      int startCheck = indexRouteActuel > 0 ? indexRouteActuel - 1 : 0;
      
      // On ne check que sur les X prochains kilomètres (environ 50 points d'itinéraire, selon la densité de Valhalla)
      // Cela évite qu'un radar situé à l'autre bout de la ville nous capte si la route fait une boucle
      int endCheck = (indexRouteActuel + 60 < pointsItineraire.length) 
        ? indexRouteActuel + 60 
        : pointsItineraire.length - 1;

      for (int i = startCheck; i < endCheck; i++) {
          double distFromRoute = _distanceToSegment(
              radarLat, radarLon,
              pointsItineraire[i].latitude, pointsItineraire[i].longitude,
              pointsItineraire[i+1].latitude, pointsItineraire[i+1].longitude
          );
          
          // Si le radar est mathématiquement posé à moins de 35m d'un bord de notre itinéraire
          if (distFromRoute <= 35) {
             return true;
          }
      }
      return false;
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
      await _mapController!.removeSymbols(mesRadars);
      mesRadars.clear();
    }
    if (_mapController == null) return;

    // 1. Créer la bulle contenant ton image et l'envoyer à la carte
    try {
      Uint8List bulleRadarBytes = await _creerBulleRadar();
      await _mapController!.addImage("radar_icon", bulleRadarBytes);
    } catch (e) {
      debugPrint("Erreur création bulle radar: $e");
      return; 
    }

    List<SymbolOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    
    for (var radar in mesRadarsData) {
      options.add(SymbolOptions(
        geometry: LatLng(radar['latitude'], radar['longitude']),
        iconImage: "radar_icon",
        iconSize: 0.8, // Taille de la bulle sur la carte (à ajuster selon tes goûts)
        iconAnchor: "bottom", // La pointe de la bulle indique l'emplacement précis
      ));
      datas.add({'type': 'radar', 'data': radar});
    }
    
    mesRadars = await _mapController!.addSymbols(options, datas);
  }

  void _gererOndeRadar(LatLng positionRadar) async {
    // Si l'onde tourne déjà sur ce radar, on ne fait rien
    if (_radarCibleOnde == positionRadar && _isOndeActive) return;

    // Si on change de radar, on nettoie l'ancienne onde
    _arreterOndeRadar();
    _radarCibleOnde = positionRadar;
    _isOndeActive = true;

    // On anime le cercle (60 images par seconde environ)
    _timerOnde = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted || !_isOndeActive) {
        timer.cancel();
        return;
      }

      _ondeRadius += 1.0;     // Vitesse de l'onde
      _ondeOpacity -= 0.015;  // Vitesse de disparition

      if (_ondeRadius > 60) { // Taille max de l'onde
        _ondeRadius = 0.0;
        _ondeOpacity = 1.0;
      }

      _mapController!.setGeoJsonSource("onde-source", {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [positionRadar.longitude, positionRadar.latitude]},
            "properties": {
               "radius": _ondeRadius,
               "opacity": _ondeOpacity
            }
          }
        ]
      });
    });
  }

  void _arreterOndeRadar() {
    _timerOnde?.cancel();
    _isOndeActive = false;
    _radarCibleOnde = null;
    if (_mapController != null && _estCartePrete) {
      _mapController!.setGeoJsonSource("onde-source", {"type": "FeatureCollection", "features": []});
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

  void _majMarkersEssence() async {
    if (markersEssence.isNotEmpty && _mapController != null) {
      await _mapController!.removeSymbols(markersEssence);
      markersEssence.clear();
    }
    if (!afficherEssence || _mapController == null) return;

    List<SymbolOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    
    for (var station in dataEssence) {
      String prixAffiche = "N/A";
      if (station['gazole_prix'] != null) {
        prixAffiche = "${station['gazole_prix']}€";
      } else if (station['e10_prix'] != null) {
        prixAffiche = "${station['e10_prix']}€";
      }

      String imageId = "bulle_essence_$prixAffiche";

      Uint8List imageBytes = await _creerBulleTexte(prixAffiche, Colors.orange.shade700);
      await _mapController!.addImage(imageId, imageBytes);

      options.add(SymbolOptions(
        geometry: LatLng(station['geom']['lat'], station['geom']['lon']),
        iconImage: imageId,
        iconSize: 1.3,
        iconAnchor: "bottom",
      ));
      
      datas.add({'type': 'essence', 'data': station});
    }
    
    markersEssence = await _mapController!.addSymbols(options, datas);
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
      await _mapController!.removeSymbols(markersParking);
      markersParking.clear();
    }
    if (!afficherParking || _mapController == null) return;

    List<SymbolOptions> options = [];
    List<Map<String, dynamic>> datas = [];
    
    for (var parking in dataParking) {
      String info = parking['nb_places'] != null ? "${parking['nb_places']} pl." : "P";

      String imageId = "bulle_parking_$info";

      Uint8List imageBytes = await _creerBulleTexte(info, const Color(0xFF2979FF));
      await _mapController!.addImage(imageId, imageBytes);

      options.add(SymbolOptions(
        geometry: LatLng(parking['ylat'], parking['xlong']),
        iconImage: imageId,
        iconSize: 1.3,
        iconAnchor: "bottom",
      ));
      
      datas.add({'type': 'parking', 'data': parking});
    }
    
    markersParking = await _mapController!.addSymbols(options, datas);
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
    final bool isDarkMode = MediaQuery.of(context).platformBrightness == Brightness.dark;
    final String mapStyle = isDarkMode
        ? 'https://api.maptiler.com/maps/basic-v2-dark/style.json?key=$mapTilerApiKey'
        : 'https://api.maptiler.com/maps/basic-v2/style.json?key=$mapTilerApiKey';

    return Scaffold(
      body: Stack(
        children: [
          // ── CARTE 3D MAPLIBRE ──────────────────────────────────────────────
          MaplibreMap(
            styleString: mapStyle,
            initialCameraPosition: CameraPosition(target: maPosition, zoom: 15.0),
            myLocationEnabled: true,
            myLocationRenderMode: modeNavigation ? MyLocationRenderMode.GPS : MyLocationRenderMode.NORMAL, // La fameuse flèche Waze 3D !
            // L'astuce est ici : on force explicitement le Tracking à None pendant le zoom pour éviter que le moteur natif n'interrompe l'animation !
            myLocationTrackingMode: (modeNavigation && !_estEnCoursDeZoom) 
                                      ? MyLocationTrackingMode.TrackingGPS 
                                      : MyLocationTrackingMode.None,
            compassEnabled: false,
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

              _mapController!.onSymbolTapped.add((Symbol symbol) {
                final properties = symbol.data;
                if (properties != null) {
                  final type = properties['type'];
                  final item = properties['data'];
                  if (type == 'essence') {
                    _afficherDetailsEssence(item);
                  } else if (type == 'parking') {
                    _afficherDetailsParking(item);
                  }
                }
              });

              if (gpsActif) {
                _mapController!.animateCamera(CameraUpdate.newLatLngZoom(maPosition, 15.0));
              }
            },
            onStyleLoadedCallback: () async {
              // Créer et enregistrer l'icône de destination personnalisée (damier.jpg)
              try {
                final Uint8List? markerIconBytes = await _createCustomMarketBitmap('assets/damier.jpg');
                if (markerIconBytes != null) {
                  await _mapController!.addImage("destination-icon", markerIconBytes);
                }
              } catch (e) {
                debugPrint("Erreur lors de la création de l'icone damier: $e");
              }

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
                filter: ["==", "isBorder", true],
                belowLayerId: "com.mapbox.annotations.points",
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
                filter: ["==", "isBorder", false],
                belowLayerId: "com.mapbox.annotations.points",
              );
              // Utiliser SymbolLayer au lieu de CircleLayer pour la destination avec THE damier flag
              _mapController!.addSymbolLayer(
                "route-source",
                "destination-symbol",
                const SymbolLayerProperties(
                  iconImage: "destination-icon",
                  iconSize: 1.5, // 1.5x plus grand
                  iconAllowOverlap: true,
                  iconAnchor: "bottom",
                ),
                filter: ["==", "isDestination", true]
              );
              
              // --- CONFIG ONDE ---
              _mapController!.addGeoJsonSource("onde-source", {"type": "FeatureCollection", "features": []});
              _mapController!.addCircleLayer(
                "onde-source",
                "onde-layer",
                CircleLayerProperties(
                  circleColor: "#007AFF", // Bleue pour le radar
                  circleRadius: ["get", "radius"],
                  circleOpacity: ["get", "opacity"],
                  circleStrokeWidth: 0.0,
                ),
                belowLayerId: "com.mapbox.annotations.points",
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
                                            _updateRouteGeoJson(); // Efface la ligne de la carte
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
                                  if (afficherEssence) {
                                    if (dataEssence.isEmpty) {
                                      chargerEssence();
                                    } else {
                                      _majMarkersEssence();
                                    }
                                  } else {
                                    _majMarkersEssence();
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
                                  if (afficherParking) {
                                    if (dataParking.isEmpty) {
                                      chargerParking();
                                    } else {
                                      _majMarkersParking();
                                    }
                                  } else {
                                    _majMarkersParking();
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
                                  if (afficherBornes) {
                                    if (dataBornes.isEmpty) {
                                      chargerBornes();
                                    } else {
                                      _majMarkersBornes();
                                    }
                                  } else {
                                    _majMarkersBornes();
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
                                  if (afficherTourisme) {
                                    if (dataTourisme.isEmpty) {
                                      chargerTourisme();
                                    } else {
                                      _majMarkersTourisme();
                                    }
                                  } else {
                                    _majMarkersTourisme();
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
            // Visible seulement en navigation, et si radarProcheDistance est valide
            top: (radarProcheDistance != double.infinity && modeNavigation) 
                  ? 160 
                  : -120, 
            left: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF007AFF), Color(0xFF005CE6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.blueAccent.withValues(alpha: 0.5), blurRadius: 15, offset: const Offset(0, 6)),
                  ],
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.radar, color: Colors.white, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Radar",
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            radarProcheDistance != double.infinity 
                                ? "À ${radarProcheDistance.round()} m" 
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
            
            // ── BOUTON RECENTRER (Style Waze) ────────────
            if (modeNavigation)
              Positioned(
                bottom: 160, // Même hauteur que la vitesse
                right: 16,   // Placé à droite
                child: GestureDetector(
                  onTap: () {
                    // On force la caméra à revenir sur la position actuelle en 3D
                    // Et on réactive le suivi natif pour faire réapparaître la Flèche 3D Waze !
                    _mapController?.animateCamera(
                      CameraUpdate.newCameraPosition(
                        CameraPosition(
                          target: maPosition,
                          zoom: vitesseKmh > 80 ? 15.5 : 18.0,
                          tilt: 55.0,
                          bearing: _mapController?.cameraPosition?.bearing ?? 0.0,
                        ),
                      ),
                      duration: const Duration(milliseconds: 800),
                    ).then((_) {
                       _mapController?.updateMyLocationTrackingMode(MyLocationTrackingMode.TrackingGPS);
                    });
                  },
                  child: Container(
                    width: 55,
                    height: 55,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.near_me, // Icône de flèche GPS
                        color: Colors.blueAccent,
                        size: 28,
                      ),
                    ),
                  ),
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
                              indexRouteActuel = 0;
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
                            // 1. Démarrage instantané du mode navigation 
                            // ON NE BLOQUE PAS le TrackingGPS pour que la flèche apparaisse TOUT DE SUITE
                            setState(() {
                              modeApercuTrajet = false;
                              modeNavigation = true;
                              _estEnCoursDeZoom = false; // La carte passe en "TrackingGPS" direct
                            });
                            
                            // 2. On raccroche de force le Tracking GPS immédiatement pour transformer le point en Flèche Waze
                            _mapController?.updateMyLocationTrackingMode(MyLocationTrackingMode.TrackingGPS);
                            
                            // 3. On attend 3 secondes le temps que la carte se charge, avec la flèche affichée
                            Future.delayed(const Duration(seconds: 5), () {
                                if (!mounted || _mapController == null) return;
                                
                                // 4. On déclenche la MÊME animation swoop 3D que le bouton "Recentrer"
                                _mapController?.animateCamera(
                                  CameraUpdate.newCameraPosition(
                                    CameraPosition(
                                      target: maPosition,
                                      zoom: vitesseKmh > 80 ? 15.5 : 18.0,
                                      tilt: 55.0,
                                      bearing: _mapController?.cameraPosition?.bearing ?? 0.0,
                                    ),
                                  ),
                                  duration: const Duration(milliseconds: 800),
                                ).then((_) {
                                   // On s'assure que le tracking reste bien accroché après le zoom
                                   _mapController?.updateMyLocationTrackingMode(MyLocationTrackingMode.TrackingGPS);
                                });
                            });
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
