/// 红果网络传输抽象。
///
/// App 客户端与网页客户端都经 [HongguoTransport] 发请求，测试注入假传输
/// 即可覆盖全部解析与重试逻辑，不依赖真实接口。默认实现
/// [HongguoHttpTransport] 基于 dart:io HttpClient，代理走环境变量
/// （与树内 network_client_builder 的做法一致）。
library;

import 'dart:convert';
import 'dart:io';

/// 一次 HTTP 响应：状态码、响应体文本、Set-Cookie 里的 cookie 名值对。
class HongguoHttpResponse {
  const HongguoHttpResponse({
    required this.statusCode,
    required this.body,
    this.cookies = const <String, String>{},
    this.contentLength = -1,
  });

  final int statusCode;
  final String body;
  final Map<String, String> cookies;
  final int contentLength;
}

/// 传输接口：GET/POST/HEAD，调用方自带超时（用 Future.timeout）。
abstract class HongguoTransport {
  Future<HongguoHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  });

  Future<HongguoHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
  });

  Future<HongguoHttpResponse> head(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  });
}

/// 基于 HttpClient 的传输实现。
class HongguoHttpTransport implements HongguoTransport {
  HongguoHttpTransport({HttpClient? client})
      : _client = client ?? HttpClient() {
    _client.findProxy = (Uri uri) => HttpClient.findProxyFromEnvironment(uri);
  }

  final HttpClient _client;

  Future<HongguoHttpResponse> _send(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    final HttpClientRequest request = await _client.openUrl(method, uri);
    headers.forEach((String key, String value) {
      request.headers.set(key, value);
    });
    if (body != null) request.add(body);
    final HttpClientResponse response = await request.close();
    final Map<String, String> cookies = <String, String>{};
    for (final Cookie cookie in response.cookies) {
      cookies[cookie.name] = cookie.value;
    }
    final String text = await response.transform(utf8.decoder).join();
    return HongguoHttpResponse(
      statusCode: response.statusCode,
      body: text,
      cookies: cookies,
      contentLength: response.contentLength,
    );
  }

  @override
  Future<HongguoHttpResponse> get(Uri uri,
          {Map<String, String> headers = const <String, String>{}}) =>
      _send('GET', uri, headers, null);

  @override
  Future<HongguoHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
  }) =>
      _send('POST', uri, headers, body);

  @override
  Future<HongguoHttpResponse> head(Uri uri,
          {Map<String, String> headers = const <String, String>{}}) =>
      _send('HEAD', uri, headers, null);
}

/// 红果请求失败（带中文说明）。
class HongguoRequestException implements Exception {
  const HongguoRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}
