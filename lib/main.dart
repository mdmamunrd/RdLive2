import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'permissions/permission_bootstrap.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Requires android/app/google-services.json (from the Firebase console).
  try {
    await Firebase.initializeApp();
  } catch (e) {
    // Show a readable error instead of a blank screen or a crash.
    runApp(_StartupErrorApp(message: e.toString()));
    return;
  }

  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const RdLiveApp());
}

class RdLiveApp extends StatelessWidget {
  const RdLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RdLive',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const PermissionBootstrap(child: _AuthGate()),
    );
  }
}

/// Shows Login when there is no session, Home once the user is signed in.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: AppColors.deepPurple,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.gold),
            ),
          );
        }
        return snap.hasData ? const HomeScreen() : const LoginScreen();
      },
    );
  }
}

/// Shown only if Firebase fails to start (for example, google-services.json is missing).
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RdLive',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'RdLive could not start.\n\n$message',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
