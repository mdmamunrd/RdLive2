import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'permission_service.dart';
import 'permission_texts.dart';

/// First-launch screen: explains why each permission is needed, then shows the real system
/// prompts one after another. Shown once; features re-ask later when needed.
class PermissionIntroScreen extends StatefulWidget {
  const PermissionIntroScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<PermissionIntroScreen> createState() => _PermissionIntroScreenState();
}

class _PermissionIntroScreenState extends State<PermissionIntroScreen> with WidgetsBindingObserver {
  final _svc = PermissionService.instance;
  Map<AppPermission, PermState> _states = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // back from Settings
  }

  Future<void> _refresh() async {
    final s = await _svc.statuses(PermissionService.startupSet);
    if (mounted) setState(() => _states = s);
  }

  Future<void> _finish() async {
    await _svc.markIntroDone();
    widget.onDone();
  }

  Future<void> _allow() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Let the screen finish drawing so the system dialog appears over it.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final out = await _svc.ensure(PermissionService.startupSet);
    if (!mounted) return;
    setState(() {
      _states = out.states;
      _busy = false;
    });
    if (out.blocked.isEmpty) {
      await _finish();
    } // else stay: user can open Settings for blocked ones or continue
  }

  @override
  Widget build(BuildContext context) {
    final anyBlocked = _states.values.any((s) => s == PermState.blocked || s == PermState.restricted);
    return Scaffold(
      backgroundColor: AppColors.deepPurple,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Allow access', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('RdLive needs a few permissions to work properly. You can change them any time in Settings.',
                  style: TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    for (final p in PermissionService.startupSet) _row(p),
                  ],
                ),
              ),
              if (anyBlocked)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _svc.openSettings,
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
                      child: const Text('Open Settings'),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _busy ? null : (anyBlocked ? _finish : _allow),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: Colors.black),
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Text(anyBlocked ? 'Continue' : 'Allow access', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _finish,
                child: const Text('Not now', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(AppPermission p) {
    final info = permissionInfo[p]!;
    final s = _states[p];
    final (label, color) = switch (s) {
      PermState.granted => ('Allowed', Colors.greenAccent),
      PermState.blocked => ('Blocked', Colors.orangeAccent),
      PermState.restricted => ('Restricted', Colors.orangeAccent),
      _ => ('', Colors.white54),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 22, backgroundColor: Colors.white12, child: Icon(info.icon, color: AppColors.gold)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(info.why, style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
              ],
            ),
          ),
          if (label.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 8, top: 2), child: Text(label, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
