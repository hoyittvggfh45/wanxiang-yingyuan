/// 引导页「授予权限」应展示的权限项取舍。
///
/// 背景：旧版存储权限（[Permission.storage]）在新版安卓（SDK 33+，分权限
/// 时代）与鸿蒙系统设置里根本没有对应开关，展示该行只会恒显示「未授权」，
/// 且点授权也永远成功不了（用户华为手机实报）。因此：
///
/// - 新版安卓（SDK >= 33）或鸿蒙：不展示旧存储权限行，只展示照片/视频/
///   音频三项分权限（隐藏而非标「无需授权」：该行描述的权限系统根本不
///   提供，任何状态展示都是假的；下载位置见引导页下方的下载目录区，
///   默认走应用专属目录，本就无需存储权限）。
/// - 旧版安卓（SDK < 33）：保留全部四项，原行为不变。
/// - SDK 读不到（通道失败）：按旧版处理（展示全部），避免误伤旧设备。
///
/// 选择逻辑是纯函数（见 [visibleOnboardingPermissions]），便于测试；
/// SDK 读取走与 [ImageSaver] 相同的原生通道（`wxyy/media_store` 的
/// `sdkInt` 方法），失败返回 null。
library;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:permission_handler/permission_handler.dart';

/// 读 Android SDK 版本（失败/非安卓返回 null）。
Future<int?> fetchAndroidSdkInt() async {
  const MethodChannel channel = MethodChannel('wxyy/media_store');
  try {
    final int? sdk = await channel.invokeMethod<int>('sdkInt');
    if (sdk == null || sdk <= 0) return null;
    return sdk;
  } catch (_) {
    return null;
  }
}

/// 引导页应展示的权限项（顺序即展示顺序）。
List<Permission> visibleOnboardingPermissions({
  required bool isOHOS,
  required int? androidSdkInt,
}) {
  final bool modern =
      isOHOS || (androidSdkInt != null && androidSdkInt >= 33);
  if (modern) {
    return const <Permission>[
      Permission.photos,
      Permission.videos,
      Permission.audio,
    ];
  }
  return const <Permission>[
    Permission.storage,
    Permission.photos,
    Permission.videos,
    Permission.audio,
  ];
}
