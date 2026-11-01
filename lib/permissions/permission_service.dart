import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The runtime permissions RdLive uses.
enum AppPermission { notifications, camera, microphone, media }

/// App-level state (plugin statuses folded into four values).
enum PermState {
  granted,
  /// Not granted, but the system prompt can still be shown.
  denied,
  /// "Don't ask again" (Android) / denied once (iOS): only the Settings app can fix it.
  blocked,
  /// Restricted by parental controls / device policy.
  restricted;

  bool get isGranted => this == PermState.granted;
  bool get canPrompt => this == PermState.denied;
}

/// Thin seam over the plugin so the logic can be unit-tested without a device.
abstract class PermissionBackend {
  Future<PermState> status(AppPermission p);
  Future<PermState> request(AppPermission p);
  Future<bool> openSettings();
}

class PluginPermissionBackend implements PermissionBackend {
  int? _androidSdk;

  Future<Permission> _resolve(AppPermission p) async {
    switch (p) {
      case AppPermission.notifications:
        return Permission.notification;
      case AppPermission.camera:
        return Permission.camera;
      case AppPermission.microphone:
        return Permission.microphone;
      case AppPermission.media:
        if (Platform.isIOS) return Permission.photos;
        // Android 13+ (API 33) uses READ_MEDIA_IMAGES; older versions use READ_EXTERNAL_STORAGE.
        _androidSdk ??= (await DeviceInfoPlugin().androidInfo).version.sdkInt;
        return _androidSdk! >= 33 ? Permission.photos : Permission.storage;
    }
  }

  static PermState _map(PermissionStatus s) {
    switch (s) {
      case PermissionStatus.granted:
      case PermissionStatus.limited: // iOS limited photos / Android 14 partial access
      case PermissionStatus.provisional:
        return PermState.granted;
      case PermissionStatus.denied:
        return PermState.denied;
      case PermissionStatus.permanentlyDenied:
        return PermState.blocked;
      case PermissionStatus.restricted:
        return PermState.restricted;
    }
  }

  @override
  Future<PermState> status(AppPermission p) async => _map(await (await _resolve(p)).status);

  @override
  Future<PermState> request(AppPermission p) async => _map(await (await _resolve(p)).request());

  @override
  Future<bool> openSettings() => openAppSettings();
}

class PermissionOutcome {
  const PermissionOutcome(this.states);
  final Map<AppPermission, PermState> states;

  bool get allGranted => states.values.every((s) => s.isGranted);
  List<AppPermission> get missing =>
      [for (final e in states.entries) if (!e.value.isGranted) e.key];
  /// Missing permissions that can only be fixed from system Settings.
  List<AppPermission> get blocked =>
      [for (final e in states.entries) if (e.value == PermState.blocked || e.value == PermState.restricted) e.key];
}

/// Single entry point for every permission in the app.
class PermissionService {
  PermissionService({PermissionBackend? backend}) : _backend = backend ?? PluginPermissionBackend();

  static final PermissionService instance = PermissionService();

  /// Permissions asked on first launch, in this order.
  static const startupSet = [
    AppPermission.notifications,
    AppPermission.camera,
    AppPermission.microphone,
    AppPermission.media,
  ];
  static const liveSet = [AppPermission.camera, AppPermission.microphone];
  static const voiceSet = [AppPermission.microphone];
  static const cameraSet = [AppPermission.camera];
  static const chatImageSet = [AppPermission.media];

  static const _introKey = 'permission_intro_done_v1';

  final PermissionBackend _backend;

  // Android (and iOS) allow only ONE system prompt at a time; a second request while one is
  // showing fails or returns "denied" without a dialog. All requests are therefore serialised.
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() job) {
    final next = _queue.then((_) => job());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<PermState> status(AppPermission p) => _backend.status(p);

  Future<Map<AppPermission, PermState>> statuses(Iterable<AppPermission> list) async =>
      {for (final p in list) p: await _backend.status(p)};

  /// Shows the system prompt for [p] unless it is already granted or can no longer be shown.
  Future<PermState> request(AppPermission p) => _serial(() async {
        final current = await _backend.status(p);
        if (current != PermState.denied) return current; // granted, blocked or restricted
        return _backend.request(p);
      });

  /// Requests every permission in [needed] one after another (one system dialog at a time).
  Future<PermissionOutcome> ensure(Iterable<AppPermission> needed) async {
    final out = <AppPermission, PermState>{};
    for (final p in needed) {
      out[p] = await request(p);
    }
    return PermissionOutcome(out);
  }

  Future<bool> openSettings() => _backend.openSettings();

  Future<bool> introDone() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_introKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> markIntroDone() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_introKey, true);
    } catch (_) {}
  }
}
