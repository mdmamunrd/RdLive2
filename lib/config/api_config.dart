/// Central place to connect the app to your backend.
class ApiConfig {
  /// Change to your API gateway, e.g. https://api.rdlive.app
  static const String baseUrl = 'https://api.rdlive.example.com';

  /// Mock data is now off: Discover / New / Follow fetch real live rooms
  /// from `GET /v1/rooms?tab=...` on the Go backend.
  static const bool useMockData = false;

  static const Duration timeout = Duration(seconds: 15);
}
