import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';

void main() async {
  String tomtomApiKey = "gCm05RjVrOc3Ew1WlUgn9zrbjImAKW9n";
  final url = Uri.parse(
    'https://api.tomtom.com/routing/1/calculateRoute/'
    '48.8566,2.3522:48.9566,2.4522/json'
    '?key=$tomtomApiKey'
    '&instructionsType=tagged'
    '&language=fr-FR'
    '&travelMode=car'
  );

  final response = await http.get(url);
  File('tomtom_response.json').writeAsStringSync(response.body);
  print("Saved to tomtom_response.json");
}
