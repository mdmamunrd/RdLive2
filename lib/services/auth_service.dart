import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Handles Google / Facebook sign-in via Firebase, then exchanges the
/// Firebase ID token with the RdLive backend (`POST /v1/auth/social`).
class AuthService {
  AuthService._();
  static final instance = AuthService._();

  final _auth = FirebaseAuth.instance;
  String? _backendJwt;
  Future<void>? _exchangeInFlight;

  Future<void> signInWithGoogle() async {
    final account = await GoogleSignIn().signIn();
    if (account == null) throw const AuthCancelled();
    final g = await account.authentication;
    final cred = GoogleAuthProvider.credential(
      accessToken: g.accessToken,
      idToken: g.idToken,
    );
    await _finish(await _auth.signInWithCredential(cred), 'google');
  }

  Future<void> signInWithFacebook() async {
    final result = await FacebookAuth.instance.login(
      permissions: const ['public_profile', 'email'],
    );
    if (result.status == LoginStatus.cancelled) throw const AuthCancelled();
    if (result.status != LoginStatus.success || result.accessToken == null) {
      throw Exception(result.message ?? 'Facebook login failed');
    }
    final cred = FacebookAuthProvider.credential(result.accessToken!.tokenString);
    await _finish(await _auth.signInWithCredential(cred), 'facebook');
  }

  Future<void> signOut() async {
    _backendJwt = null;
    // Each step is isolated so that Firebase is always signed out in the end.
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    try {
      await FacebookAuth.instance.logOut();
    } catch (_) {}
    await _auth.signOut();
  }

  /// Headers for authenticated backend calls.
  ///
  /// If the user is signed in to Firebase but no backend token exists yet (for example after
  /// the app was restarted), the token is requested first.
  Future<Map<String, String>> authHeaders() async {
    if (!ApiConfig.useMockData && _backendJwt == null) {
      final user = _auth.currentUser;
      if (user != null) {
        try {
          await _exchangeToken(user, _providerOf(user));
        } catch (_) {
          // The request goes out without a token and the backend answers 401.
        }
      }
    }
    return {
      'Content-Type': 'application/json',
      if (_backendJwt != null) 'Authorization': 'Bearer $_backendJwt',
    };
  }

  /// Called right after a successful Firebase sign-in.
  Future<void> _finish(UserCredential uc, String provider) async {
    if (ApiConfig.useMockData) return;
    final user = uc.user;
    if (user == null) throw Exception('Sign-in failed');
    try {
      await _exchangeToken(user, provider);
    } catch (_) {
      await signOut();
      rethrow;
    }
  }

  String _providerOf(User user) {
    for (final info in user.providerData) {
      if (info.providerId.contains('facebook')) return 'facebook';
      if (info.providerId.contains('google')) return 'google';
    }
    return 'google';
  }

  /// One exchange at a time: a second caller simply waits for the running one.
  Future<void> _exchangeToken(User user, String provider) {
    return _exchangeInFlight ??=
        _doExchange(user, provider).whenComplete(() => _exchangeInFlight = null);
  }

  /// Sends the Firebase ID token to the backend, which verifies it,
  /// creates/loads the profile (role = user by default) and returns a JWT.
  Future<void> _doExchange(User user, String provider) async {
    final idToken = await user.getIdToken();
    final res = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/v1/auth/social'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'provider': provider, 'id_token': idToken}),
        )
        .timeout(ApiConfig.timeout);
    if (res.statusCode != 200) {
      throw Exception('Server rejected login (${res.statusCode})');
    }
    _backendJwt = (jsonDecode(res.body) as Map<String, dynamic>)['access_token'] as String?;
  }
}

class AuthCancelled implements Exception {
  const AuthCancelled();
}
