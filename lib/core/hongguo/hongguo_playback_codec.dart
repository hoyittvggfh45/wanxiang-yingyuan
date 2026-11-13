/// 红果备用播放接口的响应解码与媒体密钥解码。
///
/// 移植自火蚁TV Go 核 `provider_hongguo_playback.go` 里的
/// `decodeHongguoPlaybackResponse` 与 `hongguoContentKey`：我们自己重写
/// 的解码算法，密钥材料来自服务端响应本身（响应里携带的密钥段），实现里
/// 不含写死的密钥常量。AES-CBC 解密走 pointycastle（与树内 crypto_utils
/// 同一用法）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 媒体地址校验：http/https 且长度不超过 8192（对应 Go `isProviderHTTPMediaURL` 的使用方式）。
bool hongguoIsMediaUrl(String url) {
  if (url.isEmpty || url.length > 8192) return false;
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme) return false;
  return parsed.scheme == 'http' || parsed.scheme == 'https';
}

/// Base64 解码：先标准、再无填充（对应 Go `decodeHongguoBase64`）。
List<int>? hongguoTryBase64Decode(String value) {
  final String trimmed = value.trim();
  try {
    return base64Decode(trimmed);
  } on Object {
    // 继续尝试无填充形式。
  }
  try {
    String normalized = trimmed;
    final int remainder = normalized.length % 4;
    if (remainder == 2) {
      normalized = '$normalized==';
    } else if (remainder == 3) {
      normalized = '$normalized=';
    } else if (remainder == 1) {
      return null;
    }
    return base64Decode(normalized);
  } on Object {
    return null;
  }
}

/// Base64 解码为文本，失败返回 null（供媒体地址提取用）。
String? hongguoTryBase64DecodeText(String value) {
  final List<int>? decoded = hongguoTryBase64Decode(value);
  if (decoded == null) return null;
  try {
    return utf8.decode(decoded);
  } on Object {
    return null;
  }
}

int _rotateLeft8(int value, int bits) {
  final int v = value & 0xff;
  final int n = bits & 7;
  return ((v << n) | (v >> (8 - n))) & 0xff;
}

int _onesCount(int value) {
  int count = 0;
  int v = value & 0xff;
  while (v != 0) {
    count += v & 1;
    v >>= 1;
  }
  return count;
}

List<int> _aesCbcDecrypt(List<int> cipher, List<int> key, List<int> iv) {
  final PaddedBlockCipherImpl cipherImpl = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipherImpl.init(
    false,
    PaddedBlockCipherParameters(
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
      null,
    ),
  );
  return cipherImpl.process(Uint8List.fromList(cipher)).toList();
}

/// 解码备用接口响应：`v2.` 前缀的加密响应先解密钥段再 AES-CBC 解密，
/// 否则当作明文 JSON（对应 Go `decodeHongguoPlaybackResponse`）。
List<int> decodeHongguoPlaybackResponse(String body) {
  final String text = body.trim();
  if (!text.startsWith('v2.')) return utf8.encode(text);
  final List<String> parts = text.split('.');
  if (parts.length != 3 || parts[1].length <= 4 || parts[1].length > 1028) {
    throw const FormatException('红果备用接口响应密钥无效');
  }
  final List<int> encoded = _hexDecode(parts[1].substring(4));
  if (encoded.isEmpty || encoded.length < 32) {
    throw const FormatException('红果备用接口响应密钥无效');
  }
  const List<int> mask = <int>[
    104,
    64,
    70,
    166,
    190,
    168,
    143,
    130,
    225,
    254,
    251,
    217,
    196,
    34,
    45,
    60,
    29,
    20,
    103,
    105,
  ];
  final List<int> material = List<int>.filled(encoded.length, 0);
  for (int index = 0; index < encoded.length; index++) {
    final int current = encoded[index];
    final int previous = index > 0 ? encoded[index - 1] : 109;
    final int slot = index % mask.length;
    final int salt = mask[slot] ^ (90 + 13 * slot) ^ 85;
    final int shifted = (current + 215 - 11 * index) & 0xff;
    material[index] = previous ^ salt ^ _rotateLeft8(shifted, 3);
  }
  final List<int>? ciphertext = hongguoTryBase64Decode(parts[2]);
  if (ciphertext == null || ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    throw const FormatException('红果备用接口加密响应无效');
  }
  try {
    return _aesCbcDecrypt(
        ciphertext, material.sublist(0, 16), material.sublist(16, 32));
  } on Object {
    throw const FormatException('红果备用接口响应解密失败');
  }
}

List<int> _hexDecode(String hex) {
  if (hex.length % 2 != 0) return <int>[];
  final List<int> out = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    final int? byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) return <int>[];
    out.add(byte);
  }
  return out;
}

/// 由 spade_a 解出 16 字节 CENC 内容密钥（对应 Go `hongguoContentKey`）。
///
/// app_v2 / web_v2 两种密钥版本明确不支持，抛错说明。
List<int> hongguoContentKey(String value) {
  if (value.length > 1024) {
    throw const FormatException('红果媒体密钥数据过长');
  }
  final List<int>? raw = hongguoTryBase64Decode(value);
  if (raw == null || raw.length < 3) {
    throw const FormatException('红果媒体密钥编码无效');
  }
  final int tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
  final int contentLength = raw.length - tagLength - 1;
  if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
    throw const FormatException('红果媒体密钥结构无效');
  }
  final int seed =
      raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
  final List<int> tag = List<int>.generate(
    tagLength,
    (int index) => raw[raw.length - tagLength + index] ^ seed,
  );
  final String tagText = String.fromCharCodes(tag);
  if (tagText == 'app_v2' || tagText == 'web_v2') {
    throw const FormatException('红果媒体密钥版本暂不支持');
  }
  final List<int> decoded = List<int>.filled(contentLength, 0);
  int previousEven = 250;
  int previousOdd = 85;
  for (int index = 0; index < contentLength; index++) {
    final int current = raw[1 + index];
    int previous = previousEven;
    if (index % 2 == 0) {
      previousEven = current;
    } else {
      previous = previousOdd;
      previousOdd = current;
    }
    decoded[index] = (previous ^ current) - 21 - _onesCount(index);
    decoded[index] &= 0xff;
  }
  final int? padding = int.tryParse(String.fromCharCode(decoded[0]), radix: 36);
  if (padding == null || contentLength - padding - 1 != 32) {
    throw const FormatException('红果媒体密钥内容无效');
  }
  final String keyHex = String.fromCharCodes(decoded.sublist(1, 33));
  final List<int> key = _hexDecode(keyHex);
  if (key.length != 16) {
    throw const FormatException('红果媒体密钥不是有效的 AES-128 密钥');
  }
  return key;
}
