/// Central place to connect the app to your backend.
class ApiConfig {
  /// Change to your API gateway, e.g. https://api.rdlive.app
  static const String baseUrl = 'https://api.rdlive.example.com';

  /// Set to false once the backend endpoints exist.
  static const bool useMockData = true;

  static const Duration timeout = Duration(seconds: 15);
}
