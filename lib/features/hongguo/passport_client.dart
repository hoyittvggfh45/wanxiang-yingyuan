/// 红果通行证客户端（改写自火蚁TV passport_client.dart）。
///
/// 直连 passport.snssdk.com 的短信 / 扫码登录接口，15 秒超时。
/// 仅用于红果账号身份展示；登录不解除设备限流、不解决加密播放限制、
/// 不开通会员（见 hongguo_login_screen.dart 的限制说明原文）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hongguo_account.dart';

class PassportException implements Exception {
  PassportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class QrTicket {
  const QrTicket({required this.ticket, required this.imageUrl});

  final String ticket;
  final String imageUrl;
}

class PassportClient {
  PassportClient({HttpClient? client}) : _client = client ?? HttpClient();

  static const String _host = 'passport.snssdk.com';

  final HttpClient _client;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, String> fields,
  ) async {
    final HttpClientRequest request = await _client.postUrl(
      Uri.https(_host, path),
    );
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.headers.set('user-agent', 'Wanxiang/1.0 (Flutter)');
    request.write(Uri(queryParameters: fields).query);
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    final String body = await response.transform(utf8.decoder).join();
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw PassportException('登录服务返回异常，请稍后重试');
    }
    return decoded;
  }

  Map<String, dynamic> _payload(Map<String, dynamic> response) {
    final Object? errorCode = response['error_code'] ?? response['code'];
    if (errorCode is int && errorCode != 0) {
      throw PassportException(
        _stringField(response, <String>['message', 'error', 'msg']) ??
            '登录失败，请稍后重试',
      );
    }
    final Object? data = response['data'];
    if (data is Map<String, dynamic>) return data;
    return response;
  }

  String? _stringField(Map<String, dynamic> map, List<String> keys) {
    for (final String key in keys) {
      final Object? value = map[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  Future<void> requestSmsCode(String phone) async {
    final Map<String, dynamic> response = await _post(
      '/passport/mobile/send_code/',
      <String, String>{'mobile': phone, 'type': 'login'},
    );
    _payload(response);
  }

  Future<HongguoAccount> verifySmsCode(String phone, String code) async {
    final Map<String, dynamic> response = await _post(
      '/passport/mobile/login/',
      <String, String>{'mobile': phone, 'code': code},
    );
    final Map<String, dynamic> data = _payload(response);
    return _accountFrom(data, method: 'sms', maskedPhone: phone);
  }

  Future<QrTicket> createQrTicket() async {
    final Map<String, dynamic> response = await _post(
      '/passport/qrcode/create/',
      <String, String>{},
    );
    final Map<String, dynamic> data = _payload(response);
    final String? ticket = _stringField(data, <String>[
      'ticket',
      'qrcode_ticket',
      'token',
    ]);
    final String imageUrl =
        _stringField(data, <String>['qrcode_url', 'image_url', 'url']) ?? '';
    if (ticket == null || ticket.isEmpty) {
      throw PassportException('获取登录二维码失败，请稍后重试');
    }
    return QrTicket(ticket: ticket, imageUrl: imageUrl);
  }

  Future<HongguoAccount?> pollQrTicket(String ticket) async {
    final Map<String, dynamic> response = await _post(
      '/passport/qrcode/scan_status/',
      <String, String>{'ticket': ticket},
    );
    final Map<String, dynamic> data = _payload(response);
    final String status = _stringField(data, <String>['status', 'state']) ?? '';
    if (status == 'success' || status == 'authorized' || status == 'login') {
      return _accountFrom(data, method: 'qr');
    }
    if (status == 'expired' || status == 'cancelled' || status == 'canceled') {
      throw PassportException('二维码已失效，请重新获取');
    }
    return null;
  }

  HongguoAccount _accountFrom(
    Map<String, dynamic> data, {
    required String method,
    String maskedPhone = '',
  }) {
    final String userId =
        _stringField(data, <String>['user_id', 'uid', 'id', 'open_id']) ?? '';
    if (userId.isEmpty) {
      throw PassportException('登录返回中缺少账号信息，请稍后重试');
    }
    final String name =
        _stringField(data, <String>['nickname', 'name', 'screen_name']) ??
        '已登录账号';
    return HongguoAccount(
      userId: userId,
      displayName: name,
      maskedPhone: maskedPhone.isEmpty
          ? ''
          : HongguoAccount.maskPhone(maskedPhone),
      method: method,
    );
  }
}
