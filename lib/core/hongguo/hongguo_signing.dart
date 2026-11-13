/// 红果 App 接口请求签名接口。
///
/// 来源：火蚁TV Go 核 `provider_hongguo_player_sign.go`（播放签名）与
/// `provider_hongguo_comment_sign.go`（文字/弹幕签名）。
///
/// 硬规矩处理结果：来源两文件里各有一处写死的 32 字节签名密钥常量（Argus
/// 密钥，十六进制字符串），以及播放签名里一处 20 字节异或密钥常量，均属于
/// 类密钥常量，按任务硬规矩**不搬运**，处理办法为删除该项——运行时生成
/// 无法得到服务端认可的签名、用户也无法自填该密钥，见回报。未搬运的签名
/// 头为 X-Gorgon、X-Argus、X-Ladon。
///
/// 因此 App 接口（fqnovel.com）在本移植里是缺项：任何需要签名的请求都会
/// 抛 [HongguoSigningUnavailable]，调用方据此诚实降级到网页线。无密钥的
/// 部分已移植：X-Khronos 时间戳、X-SS-Req-Ticket、X-SS-STUB（请求体 MD5
/// 大写十六进制）与 SM3（见 hongguo_sm3.dart）。
library;

import 'dart:math';

import 'package:crypto/crypto.dart';

/// 请求签名器：给定请求要素，返回应附加的签名头。
abstract class HongguoRequestSigner {
  /// 返回签名头（键为头名，值为头值）。无法签名时抛异常。
  Map<String, String> sign({
    required String rawQuery,
    required List<int>? body,
    required String deviceId,
    required String aid,
    required DateTime now,
    required bool comment,
  });
}

/// 签名不可用：签名密钥常量未移植，App 接口请求无法签名。
class HongguoSigningUnavailable implements Exception {
  const HongguoSigningUnavailable([this.message = '红果 App 接口签名未移植，无法发起已签名请求']);

  final String message;

  @override
  String toString() => message;
}

/// 默认签名器：始终抛 [HongguoSigningUnavailable]，绝不伪造签名头。
class HongguoUnsignedSigner implements HongguoRequestSigner {
  const HongguoUnsignedSigner();

  @override
  Map<String, String> sign({
    required String rawQuery,
    required List<int>? body,
    required String deviceId,
    required String aid,
    required DateTime now,
    required bool comment,
  }) {
    throw const HongguoSigningUnavailable();
  }
}

/// 无密钥的通用头：X-Khronos（秒级时间戳）与 X-SS-Req-Ticket（毫秒级）。
Map<String, String> hongguoUnsignedHeaders(DateTime now) {
  final int seconds = now.millisecondsSinceEpoch ~/ 1000;
  return <String, String>{
    'X-Khronos': seconds.toString(),
    'X-SS-Req-Ticket': now.millisecondsSinceEpoch.toString(),
  };
}

/// X-SS-STUB：请求体 MD5 的大写十六进制；无请求体时为空字符串。
String hongguoBodyStub(List<int>? body) {
  if (body == null) return '';
  return md5.convert(body).toString().toUpperCase();
}

/// 生成 11 字节随机 nonce（签名随机数，运行时生成，不写死）。
List<int> hongguoRandomNonce([Random? random]) {
  final Random source = random ?? Random.secure();
  return List<int>.generate(11, (_) => source.nextInt(256));
}
