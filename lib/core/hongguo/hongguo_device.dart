/// 红果设备状态、轮换与退避策略。
///
/// 移植自火蚁TV Go 核 `provider_hongguo_device.go`（设备注册与轮换）、
/// `provider_hongguo_sign.go`（设备号生成）、`provider_hongguo_app.go`
/// （玩家接口负缓存窗口）与 `provider_hongguo_native_media.go`（轮换次数）。
///
/// 设备相关值一律运行时生成：设备号/安装号用密码学安全随机数生成 19 位
/// 数字；注册请求里的 openudid/clientudid/cdid 用运行时生成的 UUID 样式
/// 字符串。来源里的固定机型指纹值（具体机型/构建号）按硬规矩不照搬，改
/// 用通用运行时值，服务端是否接受未验证，见回报。
library;

import 'dart:convert';
import 'dart:math';

import 'hongguo_models.dart';

/// 设备注册地址。
const String hongguoDeviceRegisterUrl =
    'https://log.snssdk.com/service/2/device_register/';

/// 取流失败时最多轮换设备次数（对应 Go `hongguoDeviceRotations`）。
const int hongguoDeviceRotations = 3;

/// 设备注册失败后的暂停时长（对应 Go `hongguoDeviceRegisterPause`）。
const Duration hongguoDeviceRegisterPause = Duration(minutes: 10);

/// 玩家 App 接口空响应时的负缓存窗口（对应 Go `hongguoPlayerSuspendWindow`）。
const Duration hongguoPlayerSuspendWindow = Duration(seconds: 60);

/// 运行时生成 19 位数字设备号（对应 Go `newHongguoDeviceID` 的取值范围
/// 1e18 至 9e18：首位 1–8，其余 18 位随机；逐位生成，避免 64 位溢出）。
String newHongguoDeviceId([Random? random]) {
  final Random source = random ?? Random.secure();
  final StringBuffer out = StringBuffer()..write(1 + source.nextInt(8));
  for (int i = 0; i < 18; i++) {
    out.write(source.nextInt(10));
  }
  return out.toString();
}

/// 运行时生成 UUID 样式字符串（对应 Go `uuidLike` 的用途）。
String hongguoUuidLike([Random? random]) {
  final Random source = random ?? Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex =
      bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 运行时生成十六进制随机串（对应 Go `randomHex` 的用途）。
String hongguoRandomHex(int byteCount, [Random? random]) {
  final Random source = random ?? Random.secure();
  return List<int>.generate(byteCount, (_) => source.nextInt(256))
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// 设备状态：当前设备号/安装号、是否已注册、是否被限流。
class HongguoDeviceState {
  HongguoDeviceState({String? deviceId, String? installId, Random? random})
      : deviceId = deviceId ?? newHongguoDeviceId(random),
        installId = installId ?? newHongguoDeviceId(random);

  String deviceId;
  String installId;
  bool registered = false;
  bool limited = false;
  DateTime? registerPausedUntil;
  DateTime? playerSuspendedUntil;

  bool get registerPaused =>
      registerPausedUntil != null &&
      DateTime.now().isBefore(registerPausedUntil!);

  bool get playerSuspended =>
      playerSuspendedUntil != null &&
      DateTime.now().isBefore(playerSuspendedUntil!);

  void markLimited() => limited = true;

  void clearLimited() => limited = false;

  void markRegisterPaused() {
    registerPausedUntil = DateTime.now().add(hongguoDeviceRegisterPause);
  }

  void markPlayerSuspended() {
    playerSuspendedUntil = DateTime.now().add(hongguoPlayerSuspendWindow);
  }

  void clearPlayerSuspended() => playerSuspendedUntil = null;

  void applyRegistration(String newDeviceId, String newInstallId) {
    deviceId = newDeviceId;
    installId = newInstallId;
    registered = true;
    limited = false;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'deviceId': deviceId,
        'installId': installId,
        'registered': registered,
      };

  /// 恢复持久化状态：版本号与 ID 格式不对时拒绝恢复（对应 Go `restoreHongguoCatalog` 的校验）。
  static HongguoDeviceState? restore(Map<String, dynamic>? json) {
    if (json == null || json['version'] != 1) return null;
    final String deviceId = json['deviceId'] as String? ?? '';
    final String installId = json['installId'] as String? ?? '';
    if (!hongguoNumericId.hasMatch(deviceId) ||
        !hongguoNumericId.hasMatch(installId)) {
      return null;
    }
    final HongguoDeviceState state =
        HongguoDeviceState(deviceId: deviceId, installId: installId);
    state.registered = json['registered'] as bool? ?? false;
    return state;
  }
}

/// 退避延迟表：App 请求重试按尝试次数递增（1 秒、2 秒，对应 Go `hongguoAppRequest`）。
Duration hongguoAppRetryDelay(int attempt) => Duration(seconds: attempt);

/// 榜单重试延迟：尝试次数平方 × 300 毫秒（对应 Go `fetchHongguoRankingPage`）。
Duration hongguoRankingRetryDelay(int attempt) =>
    Duration(milliseconds: attempt * attempt * 300);

/// 轮换决策：给定当前尝试次数（0 起），是否还应轮换设备重试。
bool hongguoShouldRotate(int attempt) => attempt < hongguoDeviceRotations;

/// 构造设备注册请求体（对应 Go `registerHongguoDevice` 的 header/body）。
///
/// 机型等描述字段用通用运行时值，不照搬来源里的固定机型指纹；随机字段
/// 每次调用重新生成。
Map<String, dynamic> hongguoDeviceRegisterPayload(
    {Random? random, DateTime? now}) {
  final Random source = random ?? Random.secure();
  final int genTime = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return <String, dynamic>{
    'magic_tag': 'ss_app_log',
    'header': <String, dynamic>{
      'display_name': '红果免费短剧',
      'aid': 8662,
      'app_version': '7.3.5.32',
      'version_code': 73532,
      'manifest_version_code': 73532,
      'update_version_code': 73532,
      'channel': 'update_64',
      'package': 'com.phoenix.read',
      'app_language': 'zh',
      'os': 'Android',
      'os_version': '16',
      'os_api': 36,
      'device_model': 'Android Device',
      'device_brand': 'Android',
      'device_manufacturer': 'Android',
      'cpu_abi': 'arm64-v8a',
      'density_dpi': 520,
      'display_density': 'xxhdpi',
      'resolution': '2772x1280',
      'language': 'zh',
      'timezone': 8,
      'access': 'wifi',
      'openudid': hongguoRandomHex(8, source),
      'clientudid': hongguoUuidLike(source),
      'cdid': hongguoUuidLike(source),
      'region': 'CN',
      'tz_name': 'Asia/Shanghai',
      'tz_offset': 28800,
      'sim_region': 'cn',
      'device_platform': 'android',
      'not_request_sender': 0,
      'is_system_app': 0,
      'sdk_flavor': 'china',
      'rom': 'OS2.0',
      'rom_version': '1.0',
    },
    '_gen_time': genTime,
  };
}

/// 解析设备注册响应，返回（设备号，安装号）；格式不对时抛错。
({String deviceId, String installId}) parseHongguoDeviceRegisterResponse(
    String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('红果设备注册返回格式异常');
  }
  final Map<String, dynamic> result = decoded.cast<String, dynamic>();
  final String deviceId =
      hongguoMapString(result, <String>['device_id_str', 'device_id']);
  final String installId =
      hongguoMapString(result, <String>['install_id_str', 'install_id']);
  if (!hongguoNumericId.hasMatch(deviceId) ||
      !hongguoNumericId.hasMatch(installId) ||
      deviceId == '0' ||
      installId == '0') {
    throw const FormatException('红果设备注册未返回设备号');
  }
  return (deviceId: deviceId, installId: installId);
}
