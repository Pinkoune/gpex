import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';

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

class _CarteScreenState extends State<CarteScreen> {
  final MapController _mapController = MapController();
  LatLng maPosition = const LatLng(43.6046, 1.4442);
  List<Marker> mesRadars = [];
  bool gpsActif = false;
  // --- NOUVELLES VARIABLES ---
  List<LatLng> pointsItineraire = []; // La ligne bleue
  LatLng? destination; // Le point d'arrivée

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
    super.dispose();
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
  void _selectionnerSuggestion(dynamic feature) {
    final coords = feature['geometry']['coordinates'];
    final props = feature['properties'];
    final nom = props['name'] ?? props['city'] ?? 'Destination';
    _searchController.text = nom;
    _searchFocus.unfocus();
    setState(() {
      destination = LatLng(coords[1], coords[0]);
      _suggestions = [];
    });
    calculerRoute(maPosition, destination!);
    _mapController.move(destination!, 14.0);
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

  // --- FONCTION VALHALLA (L'ITINÉRAIRE) ---
  Future<void> calculerRoute(LatLng depart, LatLng arrivee) async {
    final url = Uri.parse('https://valhalla.zeusmos.fr/route');
    final corps = json.encode({
      "locations": [
        {"lat": depart.latitude, "lon": depart.longitude},
        {"lat": arrivee.latitude, "lon": arrivee.longitude},
      ],
      "costing": "auto",
      "units": "kilometers",
    });

    try {
      final reponse = await http.post(url, body: corps);
      if (reponse.statusCode == 200) {
        final data = json.decode(reponse.body);
        final shape = data['trip']['legs'][0]['shape'];

        List<LatLng> result = _decodeValhallaPolyline(shape);

        setState(() {
          pointsItineraire = result;
        });

        if (pointsItineraire.isNotEmpty) {
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(pointsItineraire),
              padding: const EdgeInsets.all(50),
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
              width: 50,
              height: 50,
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Colors.redAccent,
                size: 30,
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
      "https://odre.opendatasoft.com/api/explore/v2.1/catalog/datasets/bornes-irve/records?where=within_distance(coordonneesXY, geom'POINT(${maPosition.longitude} ${maPosition.latitude})', 15km)&limit=100",
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
            final double? lat = borne['coordonneesxy']?['lat'];
            final double? lon = borne['coordonneesxy']?['lon'];

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
            options: MapOptions(initialCenter: maPosition, initialZoom: 15.0),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tileserver.zeusmos.fr/styles/osm-liberty/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.jeremy.gps',
              ),
              PolylineLayer(
                polylines: [
                  if (pointsItineraire.isNotEmpty)
                    Polyline(
                      points: pointsItineraire,
                      color: Colors.blueAccent,
                      strokeWidth: 5.0,
                    ),
                ],
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
                    width: 36,
                    height: 36,
                    child: const Icon(
                      Icons.navigation,
                      color: Colors.blueAccent,
                      size: 32,
                    ),
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

          // ── BARRE DE RECHERCHE + CHIPS ────────────────────────────────────
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
                    // Chips (masquées pendant la recherche active)
                    if (!_searchFocus.hasFocus) ...[
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
                  ],
                ),
              ),
            ),
          ),

          // ── SUGGESTIONS (Positioned séparé pour éviter le clipping) ───────
          if (_searchFocus.hasFocus && _suggestions.isNotEmpty)
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
        ],
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
