class LatLng {
  final double latitude;
  final double longitude;
  LatLng(this.latitude, this.longitude);
}

void main() {
  List<Map<String, dynamic>> points = [
    {"latitude": 43, "longitude": 1.5}
  ];

  try {
    List<LatLng> res = points.map((p) => LatLng(p['latitude'], p['longitude'])).toList();
    print("Success!");
  } catch (e) {
    print("Error: $e");
  }
}
