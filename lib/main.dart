import 'package:flutter/material.dart';
import 'package:maplibre_gl/mapbox_gl.dart'; // Remplace flutter_map et latlong2
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui'; // Pour le BackdropFilter (Glassmorphism)
import 'package:geolocator/geolocator.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' show Point;
import 'package:shared_preferences/shared_preferences.dart'; // Pour l'historique et les favoris

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
  String instructionDistance = ""; // Distance jusqu'à la manœuvre
  String instructionManeuver = ""; // Le type (ex: TURN_LEFT)
  bool isExitInstruction = false; // Vrai si on sort d'une autoroute
  List<dynamic> activeInstructions = []; // Le tableau brut renvoyé par TomTom
  bool _estCartePrete = false; // Flag pour s'assurer que la carte est prête
  LatLng maPosition = const LatLng(43.6046, 1.4442);
  List<dynamic> mesRadarsData = [];
  bool gpsActif = false;
  int indexRouteActuel = 0;
  bool _enCoursDeRecalcul = false;
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée
  String? destinationNom; // Le nom de la destination pour l'affichage Coyote
  bool modeNavigation = false; // Mode GPS Waze-like activé
  double vitesseKmh = 0.0; // Vitesse du véhicule
  double vitesseLimiteCible = 0.0; // Vitesse réglementée max
  List<int> pointsSpeedLimit = []; // Limitations par Shape Index
  List<TrafficSegment> segmentsTrafic = []; // Segments de couleurs calculés

  // --- COYOTE ROUTES ---
  List<Map<String, dynamic>> routesAlternatives = [];
  int indexRouteSelectionnee = 0;
  Timer? _timerCoyoteAutoStart; // Timer pour lancer la navigation automatiquement
  double _coyoteAutoStartProgress = 0.0; // Progression du bouton Démarrer (0 à 1)
  bool _isCoyoteSheetExpanded = false; //BottomSheet drag status
  int _currentRouteRequestId = 0; // Pour éviter les retours async tardifs apres annulation

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
  
  // --- NOUVELLE UI RECHERCHE WAZE ---
  bool _isSearchExpanded = false;
  String? _typeFavoriEnConfiguration;
  List<Map<String, dynamic>> _historiqueRecherche = []; 
  Map<String, dynamic>? _favoriDomicile; 
  Map<String, dynamic>? _favoriTravail;
  List<Map<String, dynamic>> _autresFavoris = [];

  @override
  void initState() {
    super.initState();
    _activerGPS();
    _chargerDonneesRecherche(); // Charger Historique et Favoris
  }

  // --- LOGIQUE SHARED PREFERENCES ---
  Future<void> _chargerDonneesRecherche() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // Charger Historique
      final String? histoStr = prefs.getString('historyNavigation');
      if (histoStr != null) {
        List<dynamic> decoded = json.decode(histoStr);
        _historiqueRecherche = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      // Charger Favoris
      final String? domStr = prefs.getString('favoriDomicile');
      if (domStr != null) _favoriDomicile = Map<String, dynamic>.from(json.decode(domStr));

      final String? tavStr = prefs.getString('favoriTravail');
      if (tavStr != null) _favoriTravail = Map<String, dynamic>.from(json.decode(tavStr));
      
      final String? favStr = prefs.getString('autresFavoris');
      if (favStr != null) {
        List<dynamic> decoded = json.decode(favStr);
        _autresFavoris = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    });
  }

  Future<void> _sauvegarderHistorique(Map<String, String> format, List<dynamic> coords) async {
    final prefs = await SharedPreferences.getInstance();
    final nouvelleEntree = {
      "titre": format["titre"],
      "sousTitre": format["sousTitre"],
      "lat": coords[1],
      "lon": coords[0],
    };

    // Éviter les doublons simples (basé sur le titre)
    _historiqueRecherche.removeWhere((item) => item["titre"] == nouvelleEntree["titre"]);
    
    // Ajouter tout au-dessus
    _historiqueRecherche.insert(0, nouvelleEntree);
    
    // Garder seulement les 10 derniers
    if (_historiqueRecherche.length > 10) {
      _historiqueRecherche = _historiqueRecherche.sublist(0, 10);
    }
    await prefs.setString('historyNavigation', json.encode(_historiqueRecherche));
    setState(() {});
  }

  Future<void> _sauvegarderFavori(String type, Map<String, String> format, List<dynamic> coords) async {
    final prefs = await SharedPreferences.getInstance();
    final nouvelleEntree = {
      "titre": format["titre"],
      "sousTitre": format["sousTitre"],
      "lat": coords[1],
      "lon": coords[0],
    };

    if (type == 'domicile') {
       _favoriDomicile = nouvelleEntree;
       await prefs.setString('favoriDomicile', json.encode(_favoriDomicile));
    } else if (type == 'travail') {
       _favoriTravail = nouvelleEntree;
       await prefs.setString('favoriTravail', json.encode(_favoriTravail));
    }
    setState(() {});
  }

  Future<void> _basculerFavoriGeneral() async {
     if (destination == null || _searchController.text.isEmpty) return;
     
     final prefs = await SharedPreferences.getInstance();
     final nom = _searchController.text;
     
     final index = _autresFavoris.indexWhere((fav) => fav['lat'] == destination!.latitude.toString() && fav['lon'] == destination!.longitude.toString());
     
     if (index >= 0) {
        _autresFavoris.removeAt(index);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Retiré des favoris")));
     } else {
        _autresFavoris.add({
           "titre": nom,
           "sousTitre": "Position enregistrée", // Fallback simplifié
           "lat": destination!.latitude.toString(),
           "lon": destination!.longitude.toString(),
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ajouté aux favoris"), backgroundColor: Colors.green));
     }
     
     await prefs.setString('autresFavoris', json.encode(_autresFavoris));
     setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // --- TOOL: CRÉATION BULLE WAZE ETA ---
  Future<Uint8List?> _createBubbleImage(String text, bool isSelected, bool isDarkMode) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    
    final Color bgColor = isSelected ? const Color(0xFF007AFF) : (isDarkMode ? const Color(0xFF2C2C2E) : Colors.white);
    final Color textColor = (isSelected || isDarkMode) ? Colors.white : Colors.black;

    final Paint paint = Paint()..color = bgColor; 
    final Paint shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
    
    // Texte principal (ex: 16 min)
    final TextSpan spanMain = TextSpan(
      style: TextStyle(color: textColor, fontSize: 36, fontWeight: FontWeight.bold),
      text: text,
    );
    final TextPainter tpMain = TextPainter(text: spanMain, textAlign: TextAlign.center, textDirection: TextDirection.ltr);
    tpMain.layout();

    // Texte secondaire (si sélectionné)
    TextPainter? tpSub;
    if (isSelected) {
       final TextSpan spanSub = TextSpan(
         style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 22, fontWeight: FontWeight.w500),
         text: "Séléctionné",
       );
       tpSub = TextPainter(text: spanSub, textAlign: TextAlign.center, textDirection: TextDirection.ltr);
       tpSub.layout();
    }
    
    final double paddingX = 24.0;
    final double paddingY = 16.0;
    final double textWidth = isSelected ? (tpMain.width > tpSub!.width ? tpMain.width : tpSub.width) : tpMain.width;
    final double textHeight = isSelected ? (tpMain.height + tpSub!.height + 4) : tpMain.height;

    final double width = textWidth + paddingX * 2;
    final double height = textHeight + paddingY * 2;
    final double pointerSize = 16.0; 

    // Ombre
    final RRect rrect = RRect.fromLTRBR(0, 0, width, height, const Radius.circular(16));
    canvas.drawRRect(rrect.shift(const Offset(0, 4)), shadowPaint);
    
    // Corps de la bulle
    canvas.drawRRect(rrect, paint);
    
    // Flèche (pointe vers le bas au centre)
    final Path path = Path();
    path.moveTo(width / 2 - pointerSize, height - 1); 
    path.lineTo(width / 2, height + pointerSize);
    path.lineTo(width / 2 + pointerSize, height - 1);
    path.close();
    
    canvas.drawPath(path.shift(const Offset(0, 2)), shadowPaint); // Ombre flèche
    canvas.drawPath(path, paint); 

    // Dessin du texte
    if (isSelected) {
       tpMain.paint(canvas, Offset((width - tpMain.width) / 2, paddingY));
       tpSub!.paint(canvas, Offset(paddingX + (textWidth - tpSub.width) / 2, paddingY + tpMain.height + 4));
    } else {
       tpMain.paint(canvas, Offset((width - tpMain.width) / 2, paddingY));
    }

    final ui.Image img = await pictureRecorder.endRecording().toImage(
      width.toInt(),
      (height + pointerSize + 8).toInt(),
    );
    final ByteData? byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
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
            }
            _updateRouteGeoJson(); // On redessine la ligne en DIRECT (Smooth 1hz update)

            // --- Real-time TomTom Instructions ---
            if (activeInstructions.isNotEmpty) {
                for (var inst in activeInstructions) {
                   int instIndex = inst['pointIndex'];
                   if (instIndex > indexRouteActuel) {
                      // C'est la prochaine instruction DEVANT nous !
                      setState(() {
                         instructionActive = inst['message'] ?? "Suivez la route";
                         instructionManeuver = inst['maneuver'] ?? "";
                         
                         // Vrai si le JSON indique une sortie OU entrée d'autoroute + un panneau
                         isExitInstruction = (instructionManeuver == "TAKE_EXIT" || instructionManeuver == "ENTER_MOTORWAY")
                                              && inst.containsKey('signpostText');
                         
                         // Calcul la distance Vol d'oiseau (Approximative)
                         if (instIndex < pointsItineraire.length) {
                             double dist = Geolocator.distanceBetween(
                                 maPosition.latitude, maPosition.longitude,
                                 pointsItineraire[instIndex].latitude, pointsItineraire[instIndex].longitude
                             );
                             if (dist > 1000) {
                                 instructionDistance = "Dans ${(dist / 1000).toStringAsFixed(1)} km";
                             } else if (dist < 40) {
                                 instructionDistance = "Maintenant";
                             } else {
                                 // Arrondi au dizaine près (ex: 142m -> 140m)
                                 instructionDistance = "Dans ${(dist / 10).round() * 10} m";
                             }
                         }
                      });
                      break; // On ne veut analyser QUE la première instruction future
                   }
                }
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
            
            // --- ARRIVAL AUTO-STOP (Fin de trajet) ---
            if (distLeftMeters <= 30 && minIndex >= pointsItineraire.length - 5) {
               debugPrint("🏁 Arrivée à destination ! Fin de l'itinéraire.");
               setState(() {
                  modeNavigation = false;
                  modeApercuTrajet = false;
                  destination = null;
                  pointsItineraire = [];
                  instructionActive = "Vous êtes arrivé";
               });
               _updateRouteGeoJson();
               _mapController?.animateCamera(
                 CameraUpdate.newCameraPosition(
                    CameraPosition(target: maPosition, zoom: 15.0, tilt: 0.0, bearing: 0.0)
                 ),
                 duration: const Duration(milliseconds: 1000)
               );
               return; // On arrête le calcul d'ETA et de caméra
            }

            // ETA dynamique proportionnel basé sur le calcul initial complet de TomTom (qui inclut le trafic)
            Map<String, dynamic> activeRoute = routesAlternatives.isNotEmpty ? routesAlternatives[indexRouteSelectionnee] : {};
            int routeTotalSeconds = activeRoute['tempsSecondes'] ?? 1;
            num routeTotalMetersNum = activeRoute['longueurMetres'] ?? 1;
            double routeTotalMeters = routeTotalMetersNum == 0 ? 1.0 : routeTotalMetersNum.toDouble();
            
            double distRatio = distLeftMeters / routeTotalMeters;
            distRatio = distRatio.clamp(0.0, 1.0); // Sécurité
            
            int secondsLeft = (routeTotalSeconds * distRatio).round();
            int hours = secondsLeft ~/ 3600;
            int mins = ((secondsLeft % 3600) / 60).ceil(); // .ceil() évite d'afficher "0 min" alors qu'on roule encore
            
            if (mins == 60) {
               hours += 1;
               mins = 0;
            }

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
          onPressed: () async {
            Navigator.pop(context); // Ferme la petite fenêtre du bas
            _searchController.text = nom; // Met le nom dans la barre de recherche
            setState(() {
              destination = cible;
              destinationNom = nom;
            });
            await calculerRoute(maPosition, destination!, transportMode);
            
            if (routesAlternatives.isEmpty) {
                if (mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Impossible de calculer l'itinéraire via TomTom."), backgroundColor: Colors.red));
                }
                setState(() {
                   destination = null;
                });
                return;
            }

            setState(() {
              modeApercuTrajet = true; // Ouvre le panneau "Démarrer"
            });
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
        "features": [
          {
            "type": "Feature",
            "geometry": { "type": "LineString", "coordinates": [[0.0, 0.0], [0.000001, 0.000001]] },
            "properties": { "color": "#000000", "isBorder": false, "routeIndex": -1 } // Ligne fantôme invisible
          }
        ]
      });
      await _mapController!.setGeoJsonSource("route-eta-source", {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "geometry": { "type": "Point", "coordinates": [0.0, 0.0] },
            "properties": { "iconImage": "none" }
          }
        ]
      });
      await _mapController!.setGeoJsonSource("route-traffic-source", {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "geometry": { "type": "LineString", "coordinates": [[0.0, 0.0], [0.000001, 0.000001]] },
            "properties": { "traffic": "clear" }
          }
        ]
      });
      return;
    }

    List<Map<String, dynamic>> features = [];
    List<Map<String, dynamic>> etaFeatures = [];

    // 0. ROUTES ALTERNATIVES (Couleur pâle - en arrière-plan)
    if (!modeNavigation && routesAlternatives.length > 1) {
        for (int i = 0; i < routesAlternatives.length; i++) {
           List<LatLng> altPoints = routesAlternatives[i]['pointsItineraire'];
           
           // Ajout de l'étiquette ETA au milieu de chaque route (principale ou alternative)
           if (altPoints.isNotEmpty) {
               int midIndex = altPoints.length ~/ 2;
               LatLng midPoint = altPoints[midIndex];
               
               String etaText = routesAlternatives[i]['etaTextApercu'];
               String imageId = 'eta_bubble_$i';
               bool isSelected = i == indexRouteSelectionnee;
               final isDarkMode = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
               
               Uint8List? bytes = await _createBubbleImage(etaText, isSelected, isDarkMode);
               if (bytes != null) {
                  await _mapController!.addImage(imageId, bytes);
               }

               etaFeatures.add({
                 "type": "Feature",
                 "geometry": { "type": "Point", "coordinates": [midPoint.longitude, midPoint.latitude] },
                 "properties": { 
                     "iconImage": imageId, 
                     "routeIndex": i 
                 }
               });
           }

           if (i == indexRouteSelectionnee) continue; // On dessine la principale par dessus ensuite
           List<List<double>> altCoords = altPoints.map((p) => [p.longitude, p.latitude]).toList();
           
           // Contour bleu des alternatives (plus discret)
           features.add({
             "type": "Feature",
             "geometry": { "type": "LineString", "coordinates": altCoords },
             "properties": { "color": "#2A5298", "isBorder": true, "routeIndex": i }
           });
           
           // Ligne principale pale
           features.add({
             "type": "Feature",
             "geometry": { "type": "LineString", "coordinates": altCoords },
             "properties": { "color": "#80A6D6", "isBorder": false, "routeIndex": i }
           });
        }
    }

    // 1. Ligne en Contour (Bordure) Route Principale
    List<List<double>> fullCoords = pointsItineraire.map((p) => [p.longitude, p.latitude]).toList();
    final isDarkModeCore = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    features.add({
      "type": "Feature",
      "geometry": { "type": "LineString", "coordinates": fullCoords },
      "properties": { "color": isDarkModeCore ? "#1C1C1E" : "#FFFFFF", "isBorder": true, "routeIndex": indexRouteSelectionnee }
    });

    // 2. Partie DÉJÀ PARCOURUE (Gris foncé / Assombri)
    if (indexRouteActuel > 0 && indexRouteActuel < pointsItineraire.length) {
      List<List<double>> coordsParcourus = pointsItineraire
          .sublist(0, indexRouteActuel + 1)
          .map((p) => [p.longitude, p.latitude])
          .toList();
          
      if (modeNavigation) {
         // Connecte fluidement la fin de la zone grise à la voiture
         coordsParcourus.add([maPosition.longitude, maPosition.latitude]);
      }
      features.add({
        "type": "Feature",
        "geometry": { "type": "LineString", "coordinates": coordsParcourus },
        "properties": { "color": "#B1D7FF", "isBorder": false } // Couleur passée
      });
    }

    // 3. Partie RESTANTE À PARCOURIR (Bleu de base)
    if (indexRouteActuel < pointsItineraire.length) {
      List<List<double>> coordsRestants = pointsItineraire
          .sublist(indexRouteActuel)
          .map((p) => [p.longitude, p.latitude])
          .toList();
          
      if (modeNavigation && coordsRestants.isNotEmpty) {
          // Accroche le début de la ligne bleue directement sous la voiture au lieu du dernier noeud
          coordsRestants[0] = [maPosition.longitude, maPosition.latitude];
      }
      features.add({
        "type": "Feature",
        "geometry": { "type": "LineString", "coordinates": coordsRestants },
        "properties": { "color": "#007AFF", "isBorder": false }
      });
    }

    // 4. Calques de Trafic par-dessus la ligne bleue
    if (segmentsTrafic.isNotEmpty) {
      for (var segment in segmentsTrafic) {
        if (segment.endIndex > indexRouteActuel) {
          int start = segment.startIndex > indexRouteActuel ? segment.startIndex : indexRouteActuel;
          int end = segment.endIndex;
          
          if (start < end && start < pointsItineraire.length) {
            List<List<double>> segCoords = pointsItineraire
                .sublist(start, end + 1)
                .map((p) => [p.longitude, p.latitude])
                .toList();
                
            if (modeNavigation && start == indexRouteActuel && segCoords.isNotEmpty) {
               // Si on roule ACTUELLEMENT sur un bouchon, on l'accroche à la voiture
               segCoords[0] = [maPosition.longitude, maPosition.latitude];
            }
            
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

    // 5. Point d'arrivée
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

    await _mapController!.setGeoJsonSource("route-eta-source", {
      "type": "FeatureCollection",
      "features": etaFeatures
    });
  }

  void _gererClicCarteRoutes(Point<double> point, LatLng latlng) async {
      if (modeNavigation || routesAlternatives.length <= 1) return;
      
      _annulerTimerCoyoteAutoStart();

      try {
          final features = await _mapController!.queryRenderedFeatures(
              point,
              ["route-layer-main", "route-layer-border", "route-eta-symbol"],
              null,
          );

          if (features.isNotEmpty) {
              var feature = features.first; // Prendre la première route sous le doigt
              // Dans MapLibre/Mapbox gl, queryRenderedFeatures retourne un json (parfois Map)
              // Vérifions les properties
              // Normalement feature c'est dynamiquement typé ou Map
              var props = feature is Map ? feature['properties'] : null; // Safety check
              // Mapbox-gl dart package renvoie souvent des objets dont les fields sont accessibles.
              // Parfois c'est juste un string JSON qu'il faut décoder si c'est mal parsé.
              // En général, dans mapbox_gl, c'est directement une Map :
              if (feature != null && feature is Map && feature.containsKey('properties')) {
                 var p = feature['properties'];
                 if (p != null) {
                    var rIndex = p['routeIndex'];
                    if (rIndex != null) {
                        int clickedIndex = (rIndex as num).toInt();
                        if (clickedIndex != indexRouteSelectionnee && clickedIndex < routesAlternatives.length) {
                            setState(() {
                               indexRouteSelectionnee = clickedIndex;
                            });
                            _appliquerRouteSelectionnee();
                        }
                    }
                 }
              }
          }
      } catch (e) {
          debugPrint("Erreur onMapClick route: $e");
      }
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
      'https://photon.komoot.io/api/?q=${Uri.encodeComponent(texte)}&lat=${maPosition.latitude}&lon=${maPosition.longitude}&limit=5&lang=fr&location_bias_scale=1',
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

  // --- HELPER D'AFFICHAGE RECHERCHE ---
  Map<String, String> _formatLieuPhoton(dynamic feature) {
    final props = feature['properties'];
    final name = props['name'];
    final housenumber = props['housenumber'];
    final street = props['street'];
    final city = props['city'];
    final postcode = props['postcode'];
    final state = props['state'];
    
    String titre = "";
    String sousTitre = "";

    // 1. Si on a un nom (ex: "McDonald's", "Tour Eiffel")
    if (name != null && name.isNotEmpty) {
      titre = name;
      // Le sous-titre devient l'adresse détaillée
      List<String> detailsAddress = [];
      if (housenumber != null && street != null) {
        detailsAddress.add("$housenumber $street");
      } else if (street != null) {
        detailsAddress.add(street);
      }
      if (postcode != null && city != null) {
        detailsAddress.add("$postcode $city");
      } else if (city != null) {
        detailsAddress.add(city);
      } else if (state != null) {
         detailsAddress.add(state);
      }
      sousTitre = detailsAddress.join(', ');
    } else {
      // 2. Pas de nom, on recherche une adresse ("34 rue de la maourine")
      if (housenumber != null && street != null) {
        titre = "$housenumber $street";
        sousTitre = city != null ? "$postcode $city".trim() : (state ?? "");
      } else if (street != null) {
        titre = street;
        sousTitre = city != null ? "$postcode $city".trim() : (state ?? "");
      } else {
        // Fallback ville simple ou truc générique
        titre = city ?? state ?? "Lieu inconnu";
        sousTitre = postcode ?? "";
      }
    }

    return {"titre": titre, "sousTitre": sousTitre.isNotEmpty ? sousTitre : "France"};
  }

  // --- SÉLECTION D'UNE SUGGESTION / HISTORIQUE / FAVORI ---
  Future<void> _selectionnerLieu(Map<String, String> format, LatLng cibleCoords, {bool isConfiguringFavorite = false, String favoriteType = ""}) async {
    final nom = format["titre"] ?? 'Destination';
    
    _searchController.text = nom;
    _searchFocus.unfocus();
    FocusScope.of(context).unfocus(); // Force la fermeture complète du clavier virtuel

    setState(() {
      _isSearchExpanded = false; // Ferme la vue plein écran
      _suggestions = [];
    });

    if (_typeFavoriEnConfiguration != null) {
       // On est en train de configurer un favori "Domicile" ou "Travail"
       await _sauvegarderFavori(_typeFavoriEnConfiguration!, format, [cibleCoords.longitude, cibleCoords.latitude]);
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$nom défini comme ${_typeFavoriEnConfiguration == 'domicile' ? 'Domicile' : 'Travail'} !"), backgroundColor: Colors.green));
       _searchController.clear();
       _typeFavoriEnConfiguration = null;
       return; 
    }

    setState(() {
      destination = cibleCoords;
      destinationNom = _searchController.text.isNotEmpty ? _searchController.text : "Destination";
    });

    // Enregistre dans l'historique seulement lors d'un vrai calcul de route
    await _sauvegarderHistorique(format, [cibleCoords.longitude, cibleCoords.latitude]);

    // Attendre le calcul de la route pour qu'elle s'affiche sur la carte globale
    await calculerRoute(maPosition, destination!, transportMode);

    if (routesAlternatives.isEmpty) {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Impossible de calculer l'itinéraire."), backgroundColor: Colors.red));
        }
        setState(() {
           destination = null;
        });
        return;
    }

    // On passe en mode aperçu si une route a été trouvée
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
           left: 50, right: 50, top: 100, bottom: 350 // Plus de padding UI
        ));
    }
  }

  // L'ancienne fonction qui appelle le Helper
  Future<void> _selectionnerSuggestion(dynamic feature, {bool isConfiguringFavorite = false, String favoriteType = ""}) async {
    final coords = feature['geometry']['coordinates'];
    final Map<String, String> format = _formatLieuPhoton(feature);
    await _selectionnerLieu(format, LatLng(coords[1], coords[0]), isConfiguringFavorite: isConfiguringFavorite, favoriteType: favoriteType);
  }

  // --- FONCTION RECHERCHE (LOOK WAZE) ---
  Future<void> _rechercherDestination(String texte) async {
    if (texte.trim().isEmpty) return;
    final url = Uri.parse(
      'https://photon.komoot.io/api/?q=${Uri.encodeComponent(texte)}&lat=${maPosition.latitude}&lon=${maPosition.longitude}&limit=1&lang=fr&location_bias_scale=1',
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

  // --- FONCTION TOMTOM (L'ITINÉRAIRE) ---
  Future<void> calculerRoute(LatLng depart, LatLng arrivee, String costing) async {
    setState(() {
      segmentsTrafic = [];
    });

    // Adaptation du mode de transport pour TomTom
    String modeTomTom = costing == 'auto' ? 'car' : costing;

    // L'URL magique TomTom : Route + Alternatives + Trafic + Instructions en 1 seul appel !
    final url = Uri.parse(
      'https://api.tomtom.com/routing/1/calculateRoute/'
      '${depart.latitude},${depart.longitude}:${arrivee.latitude},${arrivee.longitude}/json'
      '?key=$tomtomApiKey'
      '&maxAlternatives=2'
      '&computeBestOrder=false'
      '&routeType=fastest'
      '&traffic=true' // Inclus le temps de trajet avec bouchons
      '&sectionType=traffic' // Inclus les segments de couleurs pour les bouchons !
      '&instructionsType=text'
      '&language=fr-FR'
      '&travelMode=$modeTomTom'
      '&departAt=now' // Inclus l'état EXACT du trafic à l'instant T (corrige ETA sous-estimé)
    );

    final requestId = ++_currentRouteRequestId;

    try {
      final reponse = await http.get(url);
      if (reponse.statusCode == 200) {
        // Protection Anti-Cancel: si l'utilisateur a annulé pendant la requête ou fait une nouvelle recherche, on avorte.
        if (destination == null || !mounted || requestId != _currentRouteRequestId) return;

        final data = json.decode(reponse.body);
        if (data['routes'] == null) return;
        final routes = data['routes'] as List;

        List<Map<String, dynamic>> nouvellesRoutes = [];

        for (var routeData in routes) {
            final summary = routeData['summary'];
            final lengthMeters = summary['lengthInMeters'];
            final timeFormatter = summary['travelTimeInSeconds'];

            final hours = timeFormatter ~/ 3600;
            final mins = (timeFormatter % 3600) ~/ 60;

            // 1. Extraction des points (Pas besoin de décoder une polyline avec TomTom !)
            final legs = routeData['legs'][0]['points'] as List;
            List<LatLng> result = legs.map((p) => LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())).toList();

            // 2. Extraction du tableau complet d'instructions pour le suivi temps réel
            String prochaineInstruction = "En route";
            List<dynamic> tableauInstructionsText = [];
            if (routeData['guidance'] != null && routeData['guidance']['instructions'] != null) {
                final instructions = routeData['guidance']['instructions'] as List;
                tableauInstructionsText = instructions;
                if (instructions.isNotEmpty) {
                    // L'index 0 est souvent "Partez de la rue X", l'index 1 est la vraie prochaine direction
                    prochaineInstruction = instructions.length > 1 ? instructions[1]['message'] : instructions[0]['message'];
                }
            }

            // 3. Extraction MAGIQUE du trafic (Couleurs des bouchons)
            List<TrafficSegment> segmentsTraficRoute = [];
            if (routeData['sections'] != null) {
                for (var sec in routeData['sections']) {
                    if (sec['sectionType'] == 'TRAFFIC') {
                        int startIdx = sec['startPointIndex'];
                        int endIdx = sec['endPointIndex'];
                        int magnitude = sec['magnitudeOfDelay'] ?? 0;
                        
                        Color trafficColor = const Color(0xFF007AFF); // Bleu par défaut
                        if (magnitude >= 3) trafficColor = const Color(0xFFFF3B30); // Rouge (Bouchon fort)
                        else if (magnitude >= 1) trafficColor = const Color(0xFFFF9500); // Orange (Ralentissement)
                        
                        segmentsTraficRoute.add(TrafficSegment(startIdx, endIdx, trafficColor));
                    }
                }
            }

            nouvellesRoutes.add({
               "pointsItineraire": result,
               "pointsSpeedLimit": List.filled(result.length, 0), // On met 0 par défaut pour l'instant
               "instructionActive": prochaineInstruction,
               "instructionsArray": tableauInstructionsText, // <-- Le tableau complet pour les directions temps réel
               "distanceTextApercu": lengthMeters > 1000 ? "${(lengthMeters / 1000).toStringAsFixed(1)} km" : "$lengthMeters m",
               "etaTextApercu": hours > 0 ? "$hours h ${mins.toString().padLeft(2, '0')} min" : "$mins min",
               "tempsSecondes": timeFormatter,
               "longueurMetres": lengthMeters, // Permet de calculer l'ETA proportionnel
               "segmentsTrafic": segmentsTraficRoute, // On sauvegarde le trafic lié à CETTE route !
            });
        }

        if (nouvellesRoutes.isEmpty) return;

        // Tri par la route la plus rapide
        nouvellesRoutes.sort((a, b) => (a['tempsSecondes'] as num).compareTo(b['tempsSecondes'] as num));

        setState(() {
          routesAlternatives = nouvellesRoutes;
          indexRouteSelectionnee = 0; 
        });
        
        _appliquerRouteSelectionnee();

        // ── BOUTON DÉMARRER AUTO (Coyote logic) ──
        if (!modeNavigation) {
            _lancerTimerCoyoteAutoStart();
        }

        // Centrer la caméra
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
                 left: 80, right: 80, top: 80, bottom: MediaQuery.of(context).padding.bottom + 260
             )
          );
        }
      }
    } catch (e) {
      debugPrint("Erreur TomTom Routing: $e");
    }
  }

  void _appliquerRouteSelectionnee() {
      if (routesAlternatives.isEmpty || indexRouteSelectionnee >= routesAlternatives.length) return;
      var route = routesAlternatives[indexRouteSelectionnee];
      
      pointsItineraire = route["pointsItineraire"];
      pointsSpeedLimit = route["pointsSpeedLimit"];
      instructionActive = route["instructionActive"];
      activeInstructions = route["instructionsArray"] ?? []; // <-- Stocke les instructions
      distanceTextApercu = route["distanceTextApercu"];
      etaTextApercu = route["etaTextApercu"];
      segmentsTrafic = route["segmentsTrafic"]; // NOUVEAU : Charge les bouchons instantanément !
      
      indexRouteActuel = 0;
      _updateRouteGeoJson();
  }

  void _lancerTimerCoyoteAutoStart() {
      _annulerTimerCoyoteAutoStart();
      _coyoteAutoStartProgress = 0.0;
      
      const int dureeTimerMs = 10000; // Démarrage auto dans 10s
      const int tickMs = 50;
      int elapsedMs = 0;

      _timerCoyoteAutoStart = Timer.periodic(const Duration(milliseconds: tickMs), (timer) {
          if (!mounted) {
             timer.cancel();
             return;
          }
          setState(() {
              elapsedMs += tickMs;
              _coyoteAutoStartProgress = elapsedMs / dureeTimerMs;
              if (elapsedMs >= dureeTimerMs) {
                  timer.cancel();
                  _demarrerNavigation();
              }
          });
      });
  }

  void _annulerTimerCoyoteAutoStart() {
      if (_timerCoyoteAutoStart != null && _timerCoyoteAutoStart!.isActive) {
          _timerCoyoteAutoStart!.cancel();
      }
      _timerCoyoteAutoStart = null;
      setState(() {
          _coyoteAutoStartProgress = 0.0;
      });
  }

  void _demarrerNavigation() {
    _annulerTimerCoyoteAutoStart();
    setState(() {
      modeApercuTrajet = false;
      modeNavigation = true;
      _estEnCoursDeZoom = false; 
    });
    
    _updateRouteGeoJson(); // Retire les routes alternatives et bulles
    _mapController?.updateMyLocationTrackingMode(MyLocationTrackingMode.TrackingGPS);
    
    Future.delayed(const Duration(seconds: 5), () {
        if (!mounted || _mapController == null) return;
        
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: maPosition,
              zoom: vitesseKmh < 50 ? 18.0 : 16.5,
              tilt: 55.0,
              bearing: _mapController?.cameraPosition?.bearing ?? 0.0,
            ),
          ),
          duration: const Duration(milliseconds: 800),
        ).then((_) {
           _mapController?.updateMyLocationTrackingMode(MyLocationTrackingMode.TrackingGPS);
        });
    });
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

  // --- NOUVELLE UI: VUE RECHERCHE PLEIN ECRAN ---
  Widget _buildFullScreenSearch(bool isDarkMode) {
    Color bgColor = isDarkMode ? const Color(0xFF151515) : const Color(0xFFF2F2F7);
    Color cardColor = isDarkMode ? const Color(0xFF2C2C2E) : Colors.white;
    Color textColor = isDarkMode ? Colors.white : Colors.black87;
    Color hintColor = isDarkMode ? Colors.white54 : Colors.black54;

    return Container(
      key: const ValueKey("FullScreenSearchUI"),
      color: bgColor,
      child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. HEADER RECHERCHE (Bouton retour + Champ Text)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: textColor),
                      onPressed: () {
                         _searchController.clear();
                         _searchFocus.unfocus();
                         setState(() {
                            _typeFavoriEnConfiguration = null;
                            _isSearchExpanded = false;
                            _suggestions = [];
                         });
                      },
                    ),
                    Expanded(
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: isDarkMode ? [] : [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
                        ),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          autofocus: true,
                          keyboardAppearance: Brightness.dark,
                          style: TextStyle(color: textColor, fontSize: 16),
                          onTap: () {
                             if (modeApercuTrajet) {
                               setState(() {
                                 modeApercuTrajet = false;
                                 destination = null;
                                 routesAlternatives.clear();
                                 pointsItineraire.clear();
                                 pointsSpeedLimit.clear();
                                 segmentsTrafic.clear();
                                 _updateRouteGeoJson();
                                 _annulerTimerCoyoteAutoStart();
                               });
                             }
                          },
                          decoration: InputDecoration(
                            hintText: _typeFavoriEnConfiguration != null 
                                ? 'Rechercher ${_typeFavoriEnConfiguration == 'domicile' ? 'Domicile' : 'Travail'}...'
                                : 'Où allez-vous ?',
                            hintStyle: TextStyle(color: hintColor),
                            prefixIcon: Icon(Icons.search, color: hintColor),
                            suffixIcon: _searchController.text.isNotEmpty 
                               ? IconButton(
                                   icon: Icon(Icons.close, color: hintColor),
                                   onPressed: () {
                                      _searchController.clear();
                                      setState(() { _suggestions = []; });
                                   },
                                 )
                               : null,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onChanged: (v) {
                             _rechercherSuggestions(v);
                          },
                          onSubmitted: (v) {
                             if (v.isNotEmpty) {
                                _rechercherDestination(v);
                             }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              
              Divider(color: isDarkMode ? Colors.white10 : Colors.black12, height: 1),

              // 2. CORPS DE LA RECHERCHE (Suggestions OU Historique+Favoris)
              Expanded(
                child: _searchController.text.isNotEmpty
                    ? _buildResultatsRecherche(isDarkMode) // Afficher les résultats API en direct
                    : _buildHistoriqueEtFavoris(isDarkMode), // Afficher par défaut les options locales
              ),
            ],
          ),
        ),
      );
  }

  Widget _buildHistoriqueEtFavoris(bool isDarkMode) {
     Color textColor = isDarkMode ? Colors.white : Colors.black87;
     Color mutedColor = isDarkMode ? Colors.white54 : Colors.black54;

     return ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
           // FAVORIS
           Row(
             children: [
               Expanded(child: _buildBadgeFavori('domicile', 'Domicile', Icons.home, _favoriDomicile, isDarkMode)),
               const SizedBox(width: 12),
               Expanded(child: _buildBadgeFavori('travail', 'Travail', Icons.work, _favoriTravail, isDarkMode)),
             ],
           ),
           const SizedBox(height: 24),
           
           // AUTRES FAVORIS GÉNÉRAUX
           if (_autresFavoris.isNotEmpty) ...[
              Text("Lieux favoris", style: TextStyle(color: mutedColor, fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._autresFavoris.map((fav) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.star, color: Colors.orangeAccent),
                title: Text(fav["titre"]!, style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                subtitle: Text(fav["sousTitre"]!, style: TextStyle(color: mutedColor)),
                onTap: () {
                   _selectionnerLieu(
                     {"titre": fav["titre"]!, "sousTitre": fav["sousTitre"]!}, 
                     LatLng(double.parse(fav["lat"].toString()), double.parse(fav["lon"].toString())) 
                   );
                },
                onLongPress: () {
                   _afficherOptionsFavori(fav, 'autre');
                },
              )),
              const SizedBox(height: 16),
           ],

           // HISTORIQUE
           if (_historiqueRecherche.isNotEmpty) ...[
              Text("Historique récent", style: TextStyle(color: mutedColor, fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._historiqueRecherche.map((histo) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.history, color: mutedColor),
                title: Text(histo["titre"]!, style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                subtitle: Text(histo["sousTitre"]!, style: TextStyle(color: mutedColor)),
                onTap: () {
                   _selectionnerLieu(
                     {"titre": histo["titre"]!, "sousTitre": histo["sousTitre"]!}, 
                     LatLng(double.parse(histo["lat"].toString()), double.parse(histo["lon"].toString()))
                   );
                },
                onLongPress: () {
                   _afficherOptionsFavori(histo, 'historique');
                },
              )),
           ]
        ],
     );
  }

  Widget _buildBadgeFavori(String id, String label, IconData icone, Map<String, dynamic>? data, bool isDarkMode) {
     final badgeColor = isDarkMode ? const Color(0xFF2C2C2E) : Colors.white;
     final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
     final textColor = isDarkMode ? Colors.white : Colors.black87;

     return InkWell(
       onTap: () {
          if (data == null) {
             // Lancer le mode configuration pour ce favori précis !
             setState(() {
                _typeFavoriEnConfiguration = id;
                _searchController.clear();
                _searchFocus.requestFocus();
             });
          } else {
             _selectionnerLieu(
               {"titre": data["titre"]!, "sousTitre": data["sousTitre"]!}, 
               LatLng(double.parse(data["lat"].toString()), double.parse(data["lon"].toString()))
             );
          }
       },
       onLongPress: () {
          if (data != null) {
             _afficherOptionsDomicileTravail(id);
          }
       },
       borderRadius: BorderRadius.circular(12),
       child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
             color: badgeColor,
             borderRadius: BorderRadius.circular(12),
             border: Border.all(color: borderColor),
             boxShadow: isDarkMode ? [] : [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Column(
             children: [
                Icon(icone, color: data != null ? Colors.blueAccent : (isDarkMode ? Colors.white54 : Colors.black54), size: 28),
                const SizedBox(height: 8),
                Text(label, style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                if (data == null)
                  const Text("Ajouter", style: TextStyle(color: Colors.blueAccent, fontSize: 12)),
                if (data != null)
                  Text(data["sousTitre"].toString().split(',')[0], style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.black54, fontSize: 11), overflow: TextOverflow.ellipsis),
             ],
          ),
       ),
     );
  }

  Widget _buildResultatsRecherche(bool isDarkMode) {
    Color mutedColor = isDarkMode ? Colors.white54 : Colors.black54;
    Color textColor = isDarkMode ? Colors.white : Colors.black87;

    if (_suggestions.isEmpty) {
      return Center(child: Text("Recherche...", style: TextStyle(color: mutedColor)));
    }
    return ListView.separated(
      itemCount: _suggestions.length,
      separatorBuilder: (_, _) => Divider(color: isDarkMode ? Colors.white10 : Colors.black12, height: 1),
      itemBuilder: (context, index) {
        final feature = _suggestions[index];
        final coords = feature['geometry']['coordinates'];
        final Map<String, String> format = _formatLieuPhoton(feature);
        
        return ListTile(
          leading: const Icon(Icons.location_on, color: Colors.blueAccent),
          title: Text(format["titre"]!, style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
          subtitle: Text(format["sousTitre"]!, style: TextStyle(color: mutedColor)),
          onTap: () {
             _selectionnerLieu(format, LatLng(double.parse(coords[1].toString()), double.parse(coords[0].toString())));
          },
        );
      },
    );
  }

  void _afficherOptionsDomicileTravail(String id) {
     final isDarkMode = MediaQuery.of(context).platformBrightness == Brightness.dark;
     showModalBottomSheet(
        context: context,
        backgroundColor: isDarkMode ? const Color(0xFF1C1C1E) : Colors.white,
        builder: (context) {
           return SafeArea(
             child: Wrap(
                children: [
                   ListTile(
                      leading: const Icon(Icons.edit, color: Colors.blueAccent),
                      title: Text('Modifier', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87)),
                      onTap: () {
                         Navigator.pop(context);
                         setState(() {
                            _typeFavoriEnConfiguration = id;
                            _searchController.clear();
                            _searchFocus.requestFocus();
                         });
                      },
                   ),
                   ListTile(
                      leading: const Icon(Icons.delete, color: Colors.redAccent),
                      title: Text('Supprimer', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87)),
                      onTap: () async {
                         Navigator.pop(context);
                         final prefs = await SharedPreferences.getInstance();
                         setState(() {
                            if (id == 'domicile') {
                               _favoriDomicile = null;
                               prefs.remove('favoriDomicile');
                            } else {
                               _favoriTravail = null;
                               prefs.remove('favoriTravail');
                            }
                         });
                      },
                   ),
                ],
             ),
           );
        }
     );
  }

  void _afficherOptionsFavori(Map<String, dynamic> item, String type) {
     final isDarkMode = MediaQuery.of(context).platformBrightness == Brightness.dark;
     showModalBottomSheet(
        context: context,
        backgroundColor: isDarkMode ? const Color(0xFF1C1C1E) : Colors.white,
        builder: (context) {
           return SafeArea(
             child: Wrap(
                children: [
                   ListTile(
                      leading: const Icon(Icons.delete, color: Colors.redAccent),
                      title: Text('Supprimer', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87)),
                      onTap: () async {
                         Navigator.pop(context);
                         final prefs = await SharedPreferences.getInstance();
                         setState(() {
                            if (type == 'historique') {
                               _historiqueRecherche.removeWhere((i) => i['lat'] == item['lat'] && i['lon'] == item['lon']);
                               prefs.setString('historyNavigation', json.encode(_historiqueRecherche));
                            } else if (type == 'autre') {
                               _autresFavoris.removeWhere((i) => i['lat'] == item['lat'] && i['lon'] == item['lon']);
                               prefs.setString('autresFavoris', json.encode(_autresFavoris));
                            }
                         });
                      },
                   ),
                ],
             ),
           );
        }
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
          Listener(
            onPointerDown: (_) => _annulerTimerCoyoteAutoStart(),
            child: MaplibreMap(
              styleString: mapStyle,
              initialCameraPosition: CameraPosition(target: maPosition, zoom: 15.0),
              myLocationEnabled: true,
              myLocationRenderMode: modeNavigation ? MyLocationRenderMode.GPS : MyLocationRenderMode.NORMAL, 
              myLocationTrackingMode: (modeNavigation && !_estEnCoursDeZoom) 
                                        ? MyLocationTrackingMode.TrackingGPS 
                                        : MyLocationTrackingMode.None,
              compassEnabled: false,
              onMapClick: (point, latLng) {
                 _annulerTimerCoyoteAutoStart();
                 _gererClicCarteRoutes(point, latLng);
              },
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
              
              // --- ETIQUETTES TEMPS ROUTES (ETA BUBBLES) ---
              _mapController!.addGeoJsonSource("route-eta-source", {"type": "FeatureCollection", "features": []});
              _mapController!.addSymbolLayer(
                "route-eta-source",
                "route-eta-symbol",
                const SymbolLayerProperties(
                  iconImage: "{iconImage}",
                  iconSize: 1.0, // Scaled 2x
                  iconAllowOverlap: true,
                  iconIgnorePlacement: false,
                  iconAnchor: "bottom",
                ),
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
),

          // ── BARRE DE RECHERCHE + CHIPS (Cachés si mode navigation ou aperçu trajet) ────────
          if (!modeNavigation && !modeApercuTrajet && !_isSearchExpanded)
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
                              child: GestureDetector(
                                onTap: () {
                                  if (modeApercuTrajet) {
                                    setState(() {
                                      modeApercuTrajet = false;
                                      destination = null;
                                      routesAlternatives.clear();
                                      pointsItineraire.clear();
                                      pointsSpeedLimit.clear();
                                      segmentsTrafic.clear();
                                      _updateRouteGeoJson();
                                      _annulerTimerCoyoteAutoStart();
                                    });
                                  }
                                  setState(() {
                                    _isSearchExpanded = true;
                                  });
                                  // Retarder la demande de focus pour laisser l'animation de glissement se lancer
                                  Future.delayed(const Duration(milliseconds: 100), () {
                                    if (mounted && _isSearchExpanded) {
                                      _searchFocus.requestFocus();
                                    }
                                  });
                                },
                                child: Container(
                                  color: Colors.transparent, // Pour étendre la zone de clic
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.search,
                                        color: Colors.white.withValues(alpha: 0.5),
                                        size: 22,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _searchController.text.isNotEmpty 
                                            ? _searchController.text 
                                            : 'Où allez-vous ?',
                                          style: TextStyle(
                                            color: _searchController.text.isNotEmpty 
                                                ? Colors.white 
                                                : Colors.white.withValues(alpha: 0.4),
                                            fontSize: 15,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_searchController.text.isNotEmpty)
                                        GestureDetector(
                                          onTap: () {
                                            _searchController.clear();
                                            setState(() {
                                              _suggestions = [];
                                              destination = null;
                                              pointsItineraire = [];
                                              modeNavigation = false;
                                              modeApercuTrajet = false;
                                            });
                                            _updateRouteGeoJson();
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(8.0),
                                            child: Icon(
                                              Icons.close,
                                              color: Colors.white.withValues(alpha: 0.5),
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
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

          // ── VUE RECHERCHE PLEIN ÉCRAN (Où allez-vous ?) ────────
          if (_isSearchExpanded)
             Positioned.fill(
                child: _buildFullScreenSearch(isDarkMode),
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
                        // -- Icône Direction & Flèches Waze --
                        if (isExitInstruction)
                          Row(
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_upward_rounded, color: Colors.white.withValues(alpha: 0.3), size: 28),
                                  const SizedBox(height: 4),
                                  Icon(Icons.arrow_upward_rounded, color: Colors.white.withValues(alpha: 0.3), size: 28),
                                ],
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(Icons.turn_right_rounded, color: Colors.white, size: 36),
                              ),
                            ],
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                               instructionManeuver.contains("LEFT") ? Icons.turn_left :
                               instructionManeuver.contains("RIGHT") ? Icons.turn_right :
                               Icons.arrow_upward_rounded,
                               color: Colors.white,
                               size: 32
                            ),
                          ),
                          
                        const SizedBox(width: 16),
                        
                        // -- Textes --
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                instructionDistance.isNotEmpty ? instructionDistance : "Calcul en cours...",
                                style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: double.infinity,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    instructionActive,
                                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                                  ),
                                ),
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

          // ── PANNEAU APERÇU DU TRAJET (Coyote Style) ────────────
          if (modeApercuTrajet && !modeNavigation)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(
                      top: 12, 
                      left: 16, 
                      right: 16, 
                      bottom: MediaQuery.of(context).padding.bottom > 0 ? MediaQuery.of(context).padding.bottom + 16 : 24
                  ),
                  height: _isCoyoteSheetExpanded 
                      ? 470 
                      : 320 + MediaQuery.of(context).padding.bottom,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                    boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, -5))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // LA ZONE TACTILE GLOBALE POUR LE SWIPE
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (details) {
                           if (details.primaryDelta! < -10) {
                              setState(() => _isCoyoteSheetExpanded = true);
                           } else if (details.primaryDelta! > 10) {
                              setState(() => _isCoyoteSheetExpanded = false);
                           }
                        },
                        child: Column(
                          children: [
                            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(10))),
                            const SizedBox(height: 12),
                            // EN-TÊTE DESTINATION COYOTE
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    _annulerTimerCoyoteAutoStart();
                                    _currentRouteRequestId++;
                                    setState(() {
                                      modeApercuTrajet = false;
                                      destination = null;
                                      destinationNom = null;
                                      routesAlternatives = [];
                                      pointsItineraire = [];
                                      activeInstructions = [];
                                      pointsSpeedLimit = [];
                                      segmentsTrafic = [];
                                      instructionActive = "Suivez la route";
                                      instructionDistance = "";
                                    });
                                    _updateRouteGeoJson();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.all(12.0),
                                    child: Icon(Icons.arrow_back_ios, color: Colors.white, size: 22),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        destinationNom ?? "Destination",
                                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    _annulerTimerCoyoteAutoStart();
                                    _currentRouteRequestId++; // Invalide toute requête en cours
                                    setState(() {
                                      modeApercuTrajet = false;
                                      destination = null;
                                      destinationNom = null;
                                      routesAlternatives = [];
                                      pointsItineraire = [];
                                      activeInstructions = [];
                                      pointsSpeedLimit = [];
                                      segmentsTrafic = [];
                                      instructionActive = "Suivez la route";
                                      instructionDistance = "";
                                    });
                                    _updateRouteGeoJson();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.all(12.0),
                                    child: Icon(Icons.close, color: Colors.white54, size: 28),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      
                      if (!_isCoyoteSheetExpanded && routesAlternatives.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildRouteCard(routesAlternatives[indexRouteSelectionnee], indexRouteSelectionnee, true),
                      ],

                      if (_isCoyoteSheetExpanded) ...[
                          const SizedBox(height: 12),
                          Expanded(
                            child: ListView.builder(
                              physics: const BouncingScrollPhysics(),
                              itemCount: routesAlternatives.length,
                              itemBuilder: (context, index) {
                                return _buildRouteCard(routesAlternatives[index], index, false);
                              },
                            ),
                          ),
                      ],

                      if (!_isCoyoteSheetExpanded)
                          const Spacer(),
                      if (_isCoyoteSheetExpanded)
                          const SizedBox(height: 24),

                      Row(
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blueAccent.shade700,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    minimumSize: const Size(double.infinity, 54),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                    elevation: 0,
                                  ),
                                  onPressed: _demarrerNavigation,
                                  child: const Text("Démarrer", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                                ),
                                if (_coyoteAutoStartProgress > 0)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(30),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: FractionallySizedBox(
                                              widthFactor: _coyoteAutoStartProgress,
                                              child: Container(color: Colors.black.withValues(alpha: 0.15)),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: _basculerFavoriGeneral,
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(color: const Color(0xFF2C2C2E), shape: BoxShape.circle),
                              child: Builder(
                                 builder: (context) {
                                    bool estDejaFavori = destination != null && _autresFavoris.any((f) => f['lat'] == destination!.latitude.toString() && f['lon'] == destination!.longitude.toString());
                                    return Icon(estDejaFavori ? Icons.star : Icons.star_border, color: Colors.white54, size: 26);
                                 }
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ),
          ),
        ],
      ),
    );
  }

  // Widget de carte (Route Card) Coyote-style
  Widget _buildRouteCard(Map<String, dynamic> route, int index, bool isCollapsed) {
     bool isSelected = index == indexRouteSelectionnee;
     
     bool isFastest = true;
     for (var r in routesAlternatives) {
         if (r['tempsSecondes'] < route['tempsSecondes']) isFastest = false;
     }

     return GestureDetector(
       onTap: () {
          _annulerTimerCoyoteAutoStart();
          setState(() {
            indexRouteSelectionnee = index;
            if (_isCoyoteSheetExpanded) _isCoyoteSheetExpanded = false; // Replie la vue
          });
          _appliquerRouteSelectionnee();
       },
       child: Container(
          margin: EdgeInsets.only(bottom: isCollapsed ? 32 : 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
             color: isSelected ? Colors.transparent : const Color(0xFF2C2C2E),
             border: isSelected ? Border.all(color: Colors.blueAccent.shade700, width: 2) : Border.all(color: Colors.transparent),
             borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
               Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                    Text(route['etaTextApercu'], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(route['distanceTextApercu'], style: const TextStyle(fontSize: 14, color: Colors.white70)),
                    const SizedBox(height: 6),
                    Container(
                       padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                       decoration: BoxDecoration(color: const Color(0xFFD4C4FB), borderRadius: BorderRadius.circular(4)), // Couleur Coyote ZFE
                       child: const Text("Zone à Faibles Émissions", style: TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.w600)),
                    )
                 ],
               ),
               if (isFastest)
                  Container(
                     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                     decoration: BoxDecoration(color: Colors.blueAccent.shade700, borderRadius: BorderRadius.circular(20)),
                     child: Row(
                        children: [
                           const Icon(Icons.speed, color: Colors.white, size: 16),
                           const SizedBox(width: 4),
                           const Text("Rapide", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))
                        ]
                     )
                  )
               else
                  Container(
                     padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                     decoration: BoxDecoration(color: Colors.green.shade700, borderRadius: BorderRadius.circular(20)),
                     child: Row(
                        children: [
                           const Icon(Icons.eco, color: Colors.white, size: 16),
                           const SizedBox(width: 4),
                           const Text("Eco", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))
                        ]
                     )
                  )
            ],
          )
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
