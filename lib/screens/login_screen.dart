import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/festive_decor.dart';
import '../widgets/social_button.dart';

/// First screen on app launch. After a successful sign-in, the auth gate in
/// main.dart switches to HomeScreen automatically.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? _busy; // 'google' | 'facebook'

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() => _busy = key);
    try {
      await action();
    } on AuthCancelled {
      // user closed the dialog: ignore
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign-in failed. Please try again.\n$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.3,
            colors: [AppColors.purple, AppColors.deepPurple, Color(0xFF1E0B3A)],
            stops: [0, .45, 1],
          ),
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: ArchPattern(opacity: .6)),
            const Positioned(left: 24, top: 0, child: Lantern(width: 38, stringLength: 40)),
            const Positioned(
              right: 30,
              top: 0,
              child: Lantern(width: 38, stringLength: 80, color: AppColors.pink, phase: .5),
            ),
            const Positioned(top: 150, left: 32, child: Twinkle()),
            const Positioned(top: 210, right: 40, child: Twinkle(phase: .4)),
            const Positioned(top: 300, left: 70, child: Twinkle(size: 10, color: Color(0xFFFBCFE8), phase: .7)),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const Spacer(flex: 3),
                    _Logo(),
                    const SizedBox(height: 8),
                    const Text(
                      'Go live. Make friends. Shine bright. ✨',
                      style: TextStyle(color: Color(0xE6EDE9FE), fontSize: 14),
                    ),
                    const Spacer(flex: 3),
                    SocialButton(
                      label: 'Continue with Google',
                      icon: const GoogleMark(),
                      background: Colors.white,
                      foreground: AppColors.textDark,
                      loading: _busy == 'google',
                      onPressed: _busy != null
                          ? null
                          : () => _run('google', AuthService.instance.signInWithGoogle),
                    ),
                    const SizedBox(height: 12),
                    SocialButton(
                      label: 'Continue with Facebook',
                      icon: const Icon(Icons.facebook, size: 26),
                      background: AppColors.facebook,
                      foreground: Colors.white,
                      loading: _busy == 'facebook',
                      onPressed: _busy != null
                          ? null
                          : () => _run('facebook', AuthService.instance.signInWithFacebook),
                    ),
                    const SizedBox(height: 18),
                    const _TermsFooter(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF472B6), Color(0xFFA855F7), AppColors.gold],
            ),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))],
          ),
          child: const Icon(Icons.sensors_rounded, color: Colors.white, size: 54),
        ),
        const SizedBox(height: 18),
        RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1),
            children: [
              TextSpan(text: 'Rd', style: TextStyle(color: Colors.white)),
              TextSpan(text: 'Live', style: TextStyle(color: Color(0xFFFDE047))),
            ],
          ),
        ),
      ],
    );
  }
}

class _TermsFooter extends StatelessWidget {
  const _TermsFooter();

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(color: Color(0xCCDDD6FE), fontSize: 11.5, height: 1.5);
    const link = TextStyle(color: Colors.white, decoration: TextDecoration.underline);
    return const Text.rich(
      TextSpan(style: base, children: [
        TextSpan(text: 'By continuing, you agree to our '),
        // TODO: wrap with TapGestureRecognizer + url_launcher
        TextSpan(text: 'Terms of Service', style: link),
        TextSpan(text: ' and '),
        TextSpan(text: 'Privacy Policy', style: link),
        TextSpan(text: '.\n🔒 Your data is encrypted & secure.'),
      ]),
      textAlign: TextAlign.center,
    );
  }
}
