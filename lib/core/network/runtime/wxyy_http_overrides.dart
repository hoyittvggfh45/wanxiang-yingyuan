/// 全局 HttpOverrides：覆盖所有 `dart:io HttpClient` 派生流量
/// （散落的独立 Dio/HttpClient、cached_network_image、下载器、云同步等）。
///
/// 安装点：main.dart 于 `WidgetsFlutterBinding.ensureInitialized()` 后立即
/// `HttpOverrides.global = WxyyHttpOverrides()`；真实配置在 splash 加载后
/// 即时可用。
library;

import 'dart:io';

import '../network_config_service.dart';
import 'network_client_builder.dart';

/// 万象影院 全局网络覆盖。
class WxyyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final service = NetworkConfigService.instance;
    return NetworkClientBuilder.buildHttpClient(
      service.globalProfile,
      ctx: context,
      proxyPassword: service.proxyPassword,
    );
  }
}
