import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'permission_intro_screen.dart';
import 'permission_service.dart';

/// Wrap the app's first screen with this. On the first launch it shows the permission intro
/// (which triggers the system pop-ups); afterwards it shows [child] straight away.
class PermissionBootstrap extends StatefulWidget {
  const PermissionBootstrap({super.key, required this.child});
  final Widget child;

  @override
  State<PermissionBootstrap> createState() => _PermissionBootstrapState();
}

class _PermissionBootstrapState extends State<PermissionBootstrap> {
  bool? _showIntro;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final done = await PermissionService.instance.introDone();
    if (mounted) setState(() => _showIntro = !done);
  }

  @override
  Widget build(BuildContext context) {
    final show = _showIntro;
    if (show == null) {
      return const Scaffold(
        backgroundColor: AppColors.deepPurple,
        body: Center(child: CircularProgressIndicator(color: AppColors.gold)),
      );
    }
    if (show) return PermissionIntroScreen(onDone: () => setState(() => _showIntro = false));
    return widget.child;
  }
}
