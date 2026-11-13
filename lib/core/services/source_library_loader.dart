/// 源库文本加载：统一处理「随包内置源库」与「网络订阅」两种地址。
///
/// 内置源库的 manifest 与规则文件随包发布在 `assets/source_library/` 下，
/// 其订阅地址用 `asset:` 前缀哨兵表示（见 [bundledLibraryUrl]），加载时走
/// Flutter 资源（[rootBundle]），不联网、不依赖原作者的 CDN 地址。
/// 用户自填的订阅地址（http/https）走原有网络路径，不受影响。
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:wxyy/core/scraper/http_fetcher.dart';

/// 内置源库 manifest 的资源路径（`assets/source_library/index.json`）。
const String bundledLibraryManifestAsset = 'assets/source_library/index.json';

/// 内置源库的订阅地址哨兵（`asset:` + 资源路径）。
const String bundledLibraryUrl = 'asset:$bundledLibraryManifestAsset';

/// 该订阅地址是否指向随包内置源库。
bool isBundledLibraryUrl(String url) => url.trim() == bundledLibraryUrl;

/// 内置源库里某条规则的资源地址哨兵。
///
/// 清单条目的 id 形如 `manga/manga_baozimh`（分类/文件名），规则文件位于
/// `assets/source_library/sources/<id>.json`。id 里没有 `/` 时无法定位，
/// 返回 null（调用方保留原 rawUrl，走网络抓取/回退解析）。
String? bundledRuleAssetUrl(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty || !trimmed.contains('/')) return null;
  return 'asset:assets/source_library/sources/$trimmed.json';
}

/// 拉取源库文本：`asset:` 地址读包内资源，其余走网络。
Future<String> fetchLibraryText(String url) async {
  final trimmed = url.trim();
  if (trimmed.startsWith('asset:')) {
    return rootBundle.loadString(trimmed.substring('asset:'.length));
  }
  return HttpFetcher.instance.getHtml(trimmed);
}
