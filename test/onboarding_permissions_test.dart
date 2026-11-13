import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wxyy/features/onboarding/presentation/onboarding_permissions.dart';

void main() {
  test('新版安卓（SDK 33+）：不展示旧存储权限，只展示三分权限', () {
    final list = visibleOnboardingPermissions(
      isOHOS: false,
      androidSdkInt: 34,
    );
    expect(list, containsAll(<Permission>[
      Permission.photos,
      Permission.videos,
      Permission.audio,
    ]));
    expect(list, isNot(contains(Permission.storage)));
    expect(list.length, 3);
  });

  test('鸿蒙：不展示旧存储权限（与 SDK 无关）', () {
    for (final sdk in <int?>[null, 28, 34]) {
      final list = visibleOnboardingPermissions(
        isOHOS: true,
        androidSdkInt: sdk,
      );
      expect(list, isNot(contains(Permission.storage)));
      expect(list.length, 3);
    }
  });

  test('旧版安卓（SDK < 33）：保留全部四项，原行为不变', () {
    final list = visibleOnboardingPermissions(
      isOHOS: false,
      androidSdkInt: 30,
    );
    expect(list, <Permission>[
      Permission.storage,
      Permission.photos,
      Permission.videos,
      Permission.audio,
    ]);
  });

  test('SDK 读不到：按旧版处理，展示全部四项', () {
    final list = visibleOnboardingPermissions(
      isOHOS: false,
      androidSdkInt: null,
    );
    expect(list, contains(Permission.storage));
    expect(list.length, 4);
  });

  test('边界：SDK 33 正好是新版分界', () {
    expect(
      visibleOnboardingPermissions(isOHOS: false, androidSdkInt: 33),
      isNot(contains(Permission.storage)),
    );
    expect(
      visibleOnboardingPermissions(isOHOS: false, androidSdkInt: 32),
      contains(Permission.storage),
    );
  });
}
