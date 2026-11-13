/// TVBox / 猫源配置的异步解析：纯解析（`tvbox_config_parser.dart`）之后，
/// 负责需要联网的两步——下载 jar、下载 py 源码。
///
/// - jar 地址为网址时下载到应用支持目录（[JarSourceStore]），注册时
///   `spiderEngine.asset` 记 `file:<绝对路径>`；下载失败逐站报真实原因，
///   不注册坏源。下载内容须以 ZIP 魔数 `PK\x03\x04` 开头，否则按拦截页
///   / 错误地址处理（`HttpFetcher.getBytes` 不按状态码抛错，须验内容）。
/// - py 地址下载后走 [PendingPyImport] 校验，校验通过进待确认项，
///   确认时由 `PyImporter.importCode` 落盘注册；下载/校验失败逐站报原因。
/// - 下载逐个串行，不并行 burst。
/// - 非 TVBox 文本直接返回 `isRecognized: false`，不产生任何下载。
library;

import 'dart:convert';

import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import '../spider/jar_source_store.dart';
import 'pending_py_import.dart';
import 'tvbox_config_parser.dart';

/// TVBox / 猫源配置的一次完整解析结果（含下载）。
class TvboxImportOutcome {
  const TvboxImportOutcome({
    required this.isRecognized,
    required this.flavor,
    required this.configs,
    required this.pendingPy,
    required this.failures,
    required this.unsupportedSections,
  });

  /// 是否识别为 TVBox / 猫源配置。
  final bool isRecognized;

  /// 配置风味：`tvbox` 或 `catvod`。
  final String flavor;

  /// 可直接注册的源配置（采集源 + jar 已就绪的 jar 源）。
  final List<PluginConfig> configs;

  /// 待确认的 py 导入项（确认时走 `PyImporter.importCode` 注册）。
  final List<PendingPyImport> pendingPy;

  /// 逐条失败原因（形态不支持、下载失败、校验失败等）。
  final List<TvboxSiteFailure> failures;

  /// 不支持的顶层段说明。
  final List<String> unsupportedSections;
}

/// 解析一份配置文本：先纯解析判定形态，再下载 jar / py 源码。
///
/// [baseUri] 为配置文本的来源地址（网络导入/源库拉取时传入），用于解析
/// 配置内的相对 jar / py 地址；本地文件导入无基准地址，相对引用会报原因。
Future<TvboxImportOutcome> resolveTvboxConfigText(
  String text, {
  String? baseUri,
}) async {
  final TvboxParseResult parsed = parseTvboxConfig(text);
  if (!parsed.isRecognized) {
    return const TvboxImportOutcome(
      isRecognized: false,
      flavor: 'tvbox',
      configs: <PluginConfig>[],
      pendingPy: <PendingPyImport>[],
      failures: <TvboxSiteFailure>[],
      unsupportedSections: <String>[],
    );
  }
  final List<PluginConfig> configs = <PluginConfig>[];
  final List<PendingPyImport> pendingPy = <PendingPyImport>[];
  final List<TvboxSiteFailure> failures = <TvboxSiteFailure>[
    ...parsed.failures
  ];

  // 采集源：纯生成，无下载。
  for (final TvboxSiteDraft draft in parsed.drafts) {
    if (draft.kind != TvboxSiteKind.collect) continue;
    try {
      configs.add(buildCollectConfig(draft));
    } on Object catch (e) {
      failures.add(TvboxSiteFailure(
        key: draft.key,
        name: draft.name,
        reason: '生成采集源配置失败：$e',
      ));
    }
  }

  // jar 源：整份配置共用一个顶层 jar 地址，只下载一次。
  final List<TvboxSiteDraft> jarDrafts = parsed.drafts
      .where((d) => d.kind == TvboxSiteKind.jar)
      .toList(growable: false);
  String? jarAsset;
  if (jarDrafts.isNotEmpty) {
    final ({String? asset, String? reason}) resolution =
        await _resolveJarAsset(parsed.jarReference, baseUri);
    if (resolution.asset != null) {
      jarAsset = resolution.asset;
    } else {
      for (final TvboxSiteDraft draft in jarDrafts) {
        failures.add(TvboxSiteFailure(
          key: draft.key,
          name: draft.name,
          reason: resolution.reason ?? '无法取得 jar',
        ));
      }
    }
  }
  final String? resolvedJarAsset = jarAsset;
  if (resolvedJarAsset != null) {
    for (final TvboxSiteDraft draft in jarDrafts) {
      try {
        configs.add(buildJarConfig(draft, jarAsset: resolvedJarAsset));
      } on Object catch (e) {
        failures.add(TvboxSiteFailure(
          key: draft.key,
          name: draft.name,
          reason: '生成 jar 源配置失败：$e',
        ));
      }
    }
  }

  // py 源：逐个下载源码并校验。
  for (final TvboxSiteDraft draft in parsed.drafts) {
    if (draft.kind != TvboxSiteKind.py) continue;
    final String? resolved = resolveTvboxReference(draft.api, baseUri);
    if (resolved == null) {
      failures.add(TvboxSiteFailure(
        key: draft.key,
        name: draft.name,
        reason: 'py 地址是相对路径且无基准地址，无法下载：${draft.api}',
      ));
      continue;
    }
    if (!resolved.startsWith('http://') && !resolved.startsWith('https://')) {
      failures.add(TvboxSiteFailure(
        key: draft.key,
        name: draft.name,
        reason: 'py 地址不是网址，无法下载：$resolved',
      ));
      continue;
    }
    try {
      final List<int> bytes =
          await HttpFetcher.instance.getBytes(resolved, fetchDest: null);
      if (bytes.isEmpty) {
        failures.add(TvboxSiteFailure(
          key: draft.key,
          name: draft.name,
          reason: 'py 下载内容为空：$resolved',
        ));
        continue;
      }
      final String code = utf8.decode(bytes, allowMalformed: true);
      final PendingPyImport? pending = PendingPyImport.tryCreate(
        fileName: '${draft.key}.py',
        code: code,
      );
      if (pending == null) {
        failures.add(TvboxSiteFailure(
          key: draft.key,
          name: draft.name,
          reason: PendingPyImport.failureReasonOf(code),
        ));
        continue;
      }
      pendingPy.add(pending);
    } on Object catch (e) {
      failures.add(TvboxSiteFailure(
        key: draft.key,
        name: draft.name,
        reason: 'py 下载失败：$e',
      ));
    }
  }

  return TvboxImportOutcome(
    isRecognized: true,
    flavor: parsed.flavor,
    configs: configs,
    pendingPy: pendingPy,
    failures: failures,
    unsupportedSections: parsed.unsupportedSections,
  );
}

/// 解析顶层 jar 引用为原生侧可用的 jar 资源路径。
///
/// - `assets/...` 包内资源、`file:`、绝对路径：原样返回（原生侧
///   `SpiderBridge.resolveJarFile` 三路都认）；
/// - 网址：下载并验 ZIP 魔数后落盘，返回 `file:<绝对路径>`；
/// - 相对路径：有基准地址时拼成网址下载，无基准时报原因。
/// 失败返回 `asset: null` + 真实原因。
Future<({String? asset, String? reason})> _resolveJarAsset(
  String? jarReference,
  String? baseUri,
) async {
  final String ref = (jarReference ?? '').trim();
  if (ref.isEmpty) {
    return (
      asset: null,
      reason: '配置缺少顶层 jar/spider 地址，无法加载 jar 蜘蛛',
    );
  }
  if (ref.startsWith('assets/') ||
      ref.startsWith('file:') ||
      ref.startsWith('/')) {
    return (asset: ref, reason: null);
  }
  final String? resolved = resolveTvboxReference(ref, baseUri);
  if (resolved == null) {
    return (
      asset: null,
      reason: 'jar 地址是相对路径且无基准地址，无法下载：$ref',
    );
  }
  if (!resolved.startsWith('http://') && !resolved.startsWith('https://')) {
    return (
      asset: null,
      reason: 'jar 地址不是网址也不是已知资源路径：$ref',
    );
  }
  try {
    final List<int> bytes =
        await HttpFetcher.instance.getBytes(resolved, fetchDest: null);
    if (bytes.isEmpty) {
      return (asset: null, reason: 'jar 下载内容为空：$resolved');
    }
    if (!_looksLikeJar(bytes)) {
      return (
        asset: null,
        reason: '下载到的不是 jar 文件（可能被拦截或地址错误）：$resolved',
      );
    }
    final String asset = await JarSourceStore.saveJar(resolved, bytes);
    return (asset: asset, reason: null);
  } on Object catch (e) {
    return (asset: null, reason: 'jar 下载失败：$e');
  }
}

/// jar 即 ZIP 压缩包，首个条目以 `PK\x03\x04` 开头。
bool _looksLikeJar(List<int> bytes) =>
    bytes.length > 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;
