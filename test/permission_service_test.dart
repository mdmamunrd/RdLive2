import 'package:flutter_test/flutter_test.dart';
import 'package:rdlive/permissions/permission_service.dart';

class FakeBackend implements PermissionBackend {
  FakeBackend(this.state, {this.afterRequest = PermState.granted});
  final Map<AppPermission, PermState> state;
  final PermState afterRequest;
  final requested = <AppPermission>[];
  int active = 0, maxActive = 0;

  @override
  Future<PermState> status(AppPermission p) async => state[p] ?? PermState.denied;

  @override
  Future<PermState> request(AppPermission p) async {
    active++;
    if (active > maxActive) maxActive = active;
    requested.add(p);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    return state[p] = afterRequest;
  }

  @override
  Future<bool> openSettings() async => true;
}

void main() {
  test('prompts only for denied permissions, never for granted/blocked ones', () async {
    final b = FakeBackend({
      AppPermission.camera: PermState.granted,
      AppPermission.microphone: PermState.blocked,
      AppPermission.notifications: PermState.denied,
    });
    final out = await PermissionService(backend: b).ensure(
        [AppPermission.camera, AppPermission.microphone, AppPermission.notifications]);
    expect(b.requested, [AppPermission.notifications]);
    expect(out.allGranted, isFalse);
    expect(out.blocked, [AppPermission.microphone]);
    expect(out.missing, [AppPermission.microphone]);
  });

  test('concurrent callers never show two system dialogs at once', () async {
    final b = FakeBackend({});
    final s = PermissionService(backend: b);
    await Future.wait([
      s.ensure(PermissionService.startupSet),
      s.ensure(PermissionService.liveSet),
      s.request(AppPermission.microphone),
    ]);
    expect(b.maxActive, 1);
    expect(b.requested.toSet().length, b.requested.length, reason: 'each permission asked once');
  });

  test('denied result is reported as not granted and can be retried', () async {
    final b = FakeBackend({}, afterRequest: PermState.denied);
    final s = PermissionService(backend: b);
    expect((await s.ensure(PermissionService.liveSet)).allGranted, isFalse);
    expect((await s.ensure(PermissionService.liveSet)).missing.length, 2);
    expect(b.requested.length, 4);
  });
}
