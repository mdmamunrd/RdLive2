import 'dart:async';

import 'package:flutter/material.dart';

import 'permission_service.dart';
import 'permission_texts.dart';

/// Use these right before a feature that needs a permission:
///
/// ```dart
/// if (!await PermissionPrompts.forLive(context)) return;
/// ```
class PermissionPrompts {
  PermissionPrompts._();

  static final _svc = PermissionService.instance;

  /// Go Live: camera + microphone (both required).
  static Future<bool> forLive(BuildContext context) => _gate(context, PermissionService.liveSet);

  /// Taking a voice seat / speaking: microphone (required).
  static Future<bool> forVoice(BuildContext context) => _gate(context, PermissionService.voiceSet);

  /// Switching the camera on: camera (required).
  static Future<bool> forCamera(BuildContext context) => _gate(context, PermissionService.cameraSet);

  /// Sending a picture in chat: photos/media (required).
  static Future<bool> forChatImage(BuildContext context) => _gate(context, PermissionService.chatImageSet);

  /// Fire-and-forget request that never blocks the user (e.g. when merely entering a room).
  static Future<void> softAsk(Iterable<AppPermission> set) => _svc.ensure(set);

  static Future<bool> _gate(BuildContext context, List<AppPermission> needed) async {
    var outcome = await _svc.ensure(needed);
    while (!outcome.allGranted) {
      if (!context.mounted) return false;
      final retry = await _explain(context, outcome);
      if (retry != true) return false;
      outcome = await _svc.ensure(needed);
    }
    return true;
  }

  /// Returns true when the user wants another attempt (after "Try again" or returning from Settings).
  static Future<bool?> _explain(BuildContext context, PermissionOutcome outcome) {
    final names = outcome.missing.map((p) => permissionInfo[p]!.title.toLowerCase()).join(' and ');
    final needsSettings = outcome.blocked.isNotEmpty;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission needed'),
        content: Text(needsSettings
            ? 'Please allow $names in Settings > Permissions to use this feature.'
            : 'RdLive needs $names to use this feature.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(
            onPressed: () async {
              if (needsSettings) {
                final waiter = _ResumeWaiter();
                final opened = await _svc.openSettings();
                if (!opened) {
                  waiter.dispose();
                  if (ctx.mounted) Navigator.pop(ctx, false);
                  return;
                }
                // Wait until the user comes back from Settings, then re-check.
                await waiter.future;
              }
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: Text(needsSettings ? 'Open Settings' : 'Try again'),
          ),
        ],
      ),
    );
  }
}

/// Completes the next time the app returns to the foreground (e.g. back from Settings).
class _ResumeWaiter with WidgetsBindingObserver {
  _ResumeWaiter() {
    WidgetsBinding.instance.addObserver(this);
  }

  final Completer<void> _done = Completer<void>();

  Future<void> get future => _done.future;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) dispose();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_done.isCompleted) _done.complete();
  }
}
