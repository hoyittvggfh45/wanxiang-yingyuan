/// 站点备份与恢复：覆盖 [SourceRepository] 全部站点注册表。
///
/// 注册表只有一份真源：内置站（启动时从 `plugins/builtin/` 资源包加载）与
/// 用户导入的站（JSON 规则、py、订阅源库拉取、自定义源，一律经
/// `SourceRepository.addSource` 落进 `_imported`）在 [SourceRepository.all]
/// 里合并。备份就按 `all` 的口径导出，不另立清单，因此各类站点无一例外
/// 都在覆盖范围内；TVBox / 猫源只要登记进注册表（蜘蛛引擎配置），同样按
/// 通用配置 + 蜘蛛引用的方式覆盖，不依赖专用转换器。
///
/// 备份文件格式（JSON，顶层 `version` 必填）：
///
/// ```json
/// {
///   "format": "wxyy-site-backup",
///   "version": 1,
///   "exportedAt": "2026-11-13T00:00:00.000",
///   "app": "wxyy",
///   "siteCount": 3,
///   "sites": [
///     {
///       "id": "demo",
///       "kind": "json",
///       "config": { "id": "demo", "name": "...", "type": "animeSource", "...": "..." }
///     },
///     {
///       "id": "demo_py",
///       "kind": "py",
///       "config": { "...": "...", "spiderEngine": {"kind": "py", "sourceRef": "file:demo_py"} },
///       "pySource": "class Spider: ..."
///     },
///     {
///       "id": "demo_jar",
///       "kind": "jar",
///       "config": { "...": "...", "spiderEngine": {"kind": "jar", "asset": "assets/jars/zakatv.jar", "api": "csp_Demo", "ext": "{}"} },
///       "jarRef": {"asset": "assets/jars/zakatv.jar", "api": "csp_Demo", "ext": "{}"}
///     }
///   ]
/// }
/// ```
///
/// - `kind`：`json`（规则 JSON 直接存配置全文）、`py`（另内嵌 py 源码全文）、
///   `jar`（只存注册信息与 jar 引用，jar 二进制仍在包内资源，恢复时重链）。
/// - 恢复合并规则（按站点 id，绝不覆盖）：id 不存在 → 新增；id 已存在且内容
///   一致 → 跳过（报“已存在”）；id 已存在但内容不同 → 跳过并报原因；解析
///   失败 / 校验不通过 / 引用缺失 → 报失败与真实原因，不注册该站。
/// - 海阔小程序规则不在此备份内：小程序走独立的 `HaikuoStore`
///   （`haikuo/programs.json`），不在站点注册表里，这里不强行并入。
///
/// 与云同步的 `backup_archive.dart` 无关：那一路是整机数据 bundle，这里是
/// 仅站点的独立备份文件，两者格式互不兼容，恢复时按 `format` 字段区分。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/plugin_config.dart';
import '../spider/py_source_store.dart';
import 'source_repository.dart';

/// 读一份 py 蜘蛛源码（默认走 [PySourceStore.readForSource]，按 sourceRef
/// 分流资源包 / 落盘文件）。读不到返回 null，调用方照实记失败，不编内容。
typedef PySourceReader = Future<String?> Function(PluginConfig config);

/// 保存一份 py 蜘蛛源码，返回 `file:<源 id>` 形式的 sourceRef
/// （默认走 [PySourceStore.saveSource]）。
typedef PySourceWriter = Future<String> Function(String sourceId, String code);

/// 检查一个包内资源路径是否存在（默认走 `rootBundle.load` 探活）。
/// jar / py 资源引用是否齐全、恢复时重链走不走文件副本，都凭它判定。
typedef AssetExistsChecker = Future<bool> Function(String assetPath);

/// 逐站明细：导出 / 恢复过程中某站的结果说明（失败、跳过原因等）。
class SiteBackupIssue {
  const SiteBackupIssue({
    required this.siteId,
    required this.siteName,
    required this.reason,
  });

  /// 站点 id（文件级问题或无 id 条目时为空字符串）。
  final String siteId;

  /// 站点显示名（未知时为空字符串）。
  final String siteName;

  /// 中文原因说明，直接展示给用户。
  final String reason;
}

/// 导出结果：备份文件全文 + 逐站问题清单。
class SiteBackupExportResult {
  const SiteBackupExportResult({
    required this.jsonText,
    required this.total,
    required this.pyEmbedded,
    required this.pyFailures,
    required this.jarUnverified,
  });

  /// 备份文件全文（JSON，可直接落盘）。
  final String jsonText;

  /// 导出站点总数（`SourceRepository.all` 的条数）。
  final int total;

  /// 成功内嵌源码的 py 站数。
  final int pyEmbedded;

  /// py 源码读不到的站（条目仍在备份内，但 `pySource` 为空，不编假内容）。
  final List<SiteBackupIssue> pyFailures;

  /// jar 引用未能在包内确认的站（注册信息仍在备份内，恢复时重链再判）。
  final List<SiteBackupIssue> jarUnverified;

  /// 是否有需要用户知晓的问题（py 读不到 / jar 引用未确认）。
  bool get hasProblems => pyFailures.isNotEmpty || jarUnverified.isNotEmpty;
}

/// 恢复结果：逐站汇总条数 + 原因清单。
class SiteBackupRestoreResult {
  const SiteBackupRestoreResult({
    required this.added,
    required this.skippedExisting,
    required this.skippedDifferent,
    required this.failed,
    required this.issues,
    this.fileError,
  });

  /// 新增注册的站数。
  final int added;

  /// id 已存在且内容一致、跳过的站数。
  final int skippedExisting;

  /// id 已存在但内容不同、未覆盖而跳过的站数。
  final int skippedDifferent;

  /// 解析 / 校验 / 引用缺失而失败的站数（未注册）。
  final int failed;

  /// 逐站明细（跳过与失败的原因；新增的站不逐条列出）。
  final List<SiteBackupIssue> issues;

  /// 文件级错误（不是合法 JSON、format / 版本不符、缺站点列表等）。
  /// 非空时整份文件未做任何注册，[added] 等计数均为 0。
  final String? fileError;

  /// 是否文件级失败。
  bool get isFileError => fileError != null;

  /// 本次处理过的站点条数（文件级失败时为 0）。
  int get total => added + skippedExisting + skippedDifferent + failed;

  /// 文件级失败的结果（不注册任何站点）。
  factory SiteBackupRestoreResult.fileErrorResult(String reason) =>
      SiteBackupRestoreResult(
        added: 0,
        skippedExisting: 0,
        skippedDifferent: 0,
        failed: 0,
        issues: <SiteBackupIssue>[
          SiteBackupIssue(siteId: '', siteName: '', reason: reason),
        ],
        fileError: reason,
      );
}

/// 站点备份服务：导出注册表为备份文件、从备份文件合并恢复。
///
/// 读写 py 源码与探活包内资源均可注入替身（单测用）；默认实现走
/// [PySourceStore] 与 `rootBundle`，与 App 内蜘蛛引擎同一套落点。
class SiteBackupService {
  SiteBackupService({
    PySourceReader? readPySource,
    PySourceWriter? savePySource,
    AssetExistsChecker? assetExists,
  })  : _readPySource = readPySource ?? PySourceStore.readForSource,
        _savePySource = savePySource ?? PySourceStore.saveSource,
        _assetExists = assetExists ?? _defaultAssetExists;

  /// 备份文件格式标识（恢复时据此与云同步 bundle 等其它 JSON 区分）。
  static const String backupFormat = 'wxyy-site-backup';

  /// 备份格式版本（顶层 `version` 字段，必填；恢复只接受本版本）。
  static const int backupVersion = 1;

  final PySourceReader _readPySource;
  final PySourceWriter _savePySource;
  final AssetExistsChecker _assetExists;

  /// 资源探活缓存：同一份 jar 常被上百个站共用，探一次即可。
  final Map<String, bool> _assetExistsCache = <String, bool>{};

  static Future<bool> _defaultAssetExists(String assetPath) async {
    try {
      await rootBundle.load(assetPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _assetExistsCached(String assetPath) async {
    final cached = _assetExistsCache[assetPath];
    if (cached != null) return cached;
    final exists = await _assetExists(assetPath);
    _assetExistsCache[assetPath] = exists;
    return exists;
  }

  /// 导出 [repo] 全部站点为备份文件。
  ///
  /// - 规则 JSON 站：存配置全文（`PluginConfig.toJson()`）。
  /// - py 站：另内嵌 py 源码全文；读不到的站条目保留、`pySource` 置空，
  ///   并记入 [SiteBackupExportResult.pyFailures]，绝不编假源码。
  /// - jar 站：存注册信息与 jar 引用（asset / api / ext）；包内探不到
  ///   jar 资源的站记入 [SiteBackupExportResult.jarUnverified]，恢复时重链再判。
  Future<SiteBackupExportResult> exportBackup(SourceRepository repo) async {
    final sites = <Map<String, dynamic>>[];
    final pyFailures = <SiteBackupIssue>[];
    final jarUnverified = <SiteBackupIssue>[];
    var pyEmbedded = 0;

    for (final config in repo.all) {
      final kind = _kindOf(config);
      final entry = <String, dynamic>{
        'id': config.id,
        'kind': kind,
        'config': config.toJson(),
      };
      if (config.isPySource) {
        final code = await _readPySource(config);
        if (code == null || code.isEmpty) {
          pyFailures.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: 'py 源码读不到，未内嵌源码；恢复时须包内资源仍在才能用',
            ),
          );
          entry['pySource'] = null;
        } else {
          entry['pySource'] = code;
          pyEmbedded++;
        }
      } else if (config.isJarSource) {
        final engine = config.spiderEngine;
        entry['jarRef'] = <String, dynamic>{
          if (engine?.asset != null) 'asset': engine!.asset,
          if (engine?.api != null) 'api': engine!.api,
          if (engine?.ext != null) 'ext': engine!.ext,
        };
        final asset = engine?.asset;
        if (asset == null || asset.isEmpty) {
          jarUnverified.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: 'jar 站未声明 jar 资源路径，恢复时无法重链',
            ),
          );
        } else if (!await _assetExistsCached(asset)) {
          jarUnverified.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: '包内找不到 jar 资源：$asset，恢复时需重链确认',
            ),
          );
        }
      }
      sites.add(entry);
    }

    final payload = <String, dynamic>{
      'format': backupFormat,
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'app': 'wxyy',
      'siteCount': sites.length,
      'sites': sites,
    };
    return SiteBackupExportResult(
      jsonText: const JsonEncoder.withIndent('  ').convert(payload),
      total: sites.length,
      pyEmbedded: pyEmbedded,
      pyFailures: pyFailures,
      jarUnverified: jarUnverified,
    );
  }

  /// 从备份文件文本恢复站点到 [repo]，按 id 合并去重，绝不覆盖已有站点。
  ///
  /// 文件级损坏（非 JSON、format / 版本不符、缺 `sites`）直接返回
  /// [SiteBackupRestoreResult.fileError]，不注册任何站点、不抛异常。
  /// 逐站问题（解析失败、校验不通过、引用缺失）记入结果明细，该站不注册，
  /// 其余站继续处理。
  Future<SiteBackupRestoreResult> restoreBackup(
    SourceRepository repo,
    String backupText,
  ) async {
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(backupText);
      if (decoded is! Map<String, dynamic>) {
        return SiteBackupRestoreResult.fileErrorResult('备份文件顶层不是对象');
      }
      root = decoded;
    } catch (e) {
      return SiteBackupRestoreResult.fileErrorResult('备份文件不是合法 JSON：$e');
    }
    if (root['format'] != backupFormat) {
      return SiteBackupRestoreResult.fileErrorResult(
        '不是站点备份文件（缺少 format 标识，可能是其它备份格式）',
      );
    }
    if (root['version'] != backupVersion) {
      return SiteBackupRestoreResult.fileErrorResult(
        '不支持的备份版本：${root['version']}（仅支持版本 $backupVersion）',
      );
    }
    final rawSites = root['sites'];
    if (rawSites is! List) {
      return SiteBackupRestoreResult.fileErrorResult('备份文件缺少站点列表（sites）');
    }

    var added = 0;
    var skippedExisting = 0;
    var skippedDifferent = 0;
    var failed = 0;
    final issues = <SiteBackupIssue>[];
    final seenIds = <String>{};

    for (final raw in rawSites) {
      if (raw is! Map) {
        failed++;
        issues.add(
          const SiteBackupIssue(
            siteId: '',
            siteName: '',
            reason: '站点条目不是对象，已跳过',
          ),
        );
        continue;
      }
      final entry = Map<String, dynamic>.from(raw);
      final configRaw = entry['config'];
      if (configRaw is! Map) {
        failed++;
        issues.add(
          SiteBackupIssue(
            siteId: entry['id']?.toString() ?? '',
            siteName: '',
            reason: '站点条目缺少 config 配置，已跳过',
          ),
        );
        continue;
      }
      PluginConfig config;
      try {
        config = PluginConfig.fromJson(
          Map<String, dynamic>.from(configRaw),
        );
      } catch (e) {
        failed++;
        issues.add(
          SiteBackupIssue(
            siteId: entry['id']?.toString() ?? '',
            siteName: '',
            reason: '配置解析失败：$e',
          ),
        );
        continue;
      }
      if (config.id.isEmpty) {
        failed++;
        issues.add(
          const SiteBackupIssue(
            siteId: '',
            siteName: '',
            reason: '配置缺少站点 id，已跳过',
          ),
        );
        continue;
      }
      if (!seenIds.add(config.id)) {
        // 备份文件内重复的 id：只处理第一条，其余跳过并明说。
        skippedExisting++;
        issues.add(
          SiteBackupIssue(
            siteId: config.id,
            siteName: config.name,
            reason: '备份文件内重复出现，已跳过（只保留第一条）',
          ),
        );
        continue;
      }
      final errors = config.validate();
      if (errors.isNotEmpty) {
        failed++;
        issues.add(
          SiteBackupIssue(
            siteId: config.id,
            siteName: config.name,
            reason: '校验不通过：${errors.join('、')}',
          ),
        );
        continue;
      }

      final existing = repo.getById(config.id);
      if (existing != null) {
        // 已有站点一律不调用 addSource / replaceSource：addSource 带
        // 版本覆盖语义（新版本 ≥ 已装版本即替换），会违背“绝不覆盖”。
        final same = await _isSameContent(existing, config, entry);
        if (same) {
          skippedExisting++;
          issues.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: '已存在，内容一致，已跳过',
            ),
          );
        } else {
          skippedDifferent++;
          issues.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: '已存在同名站点但内容不同，未覆盖（保留现有站点）',
            ),
          );
        }
        continue;
      }

      // 新 id：先把内容落齐（py 源码落盘 / jar 引用重链确认），再注册。
      if (config.isPySource) {
        final resolved = await _resolvePyConfig(config, entry);
        if (resolved == null) {
          failed++;
          issues.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: 'py 源码缺失且包内资源找不到，无法恢复（未注册）',
            ),
          );
          continue;
        }
        config = resolved;
      } else if (config.isJarSource) {
        final asset = config.spiderEngine?.asset;
        if (asset == null || asset.isEmpty) {
          failed++;
          issues.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: 'jar 站未声明 jar 资源路径，无法重链（未注册）',
            ),
          );
          continue;
        }
        if (!await _assetExistsCached(asset)) {
          failed++;
          issues.add(
            SiteBackupIssue(
              siteId: config.id,
              siteName: config.name,
              reason: 'jar 引用缺失：包内无此资源 $asset（未注册）',
            ),
          );
          continue;
        }
      }

      repo.addSource(config);
      added++;
    }

    return SiteBackupRestoreResult(
      added: added,
      skippedExisting: skippedExisting,
      skippedDifferent: skippedDifferent,
      failed: failed,
      issues: issues,
    );
  }

  /// py 站恢复：内嵌源码落盘，并按资源是否在包内决定 sourceRef 指向。
  ///
  /// - 有内嵌源码：先落盘；原 `sourceRef` 是 `file:` 的保持原样；是
  ///   `asset:` 且包内资源仍在的保持原样（内置身份不变）；`asset:` 但包内
  ///   资源已无的，改指 `file:<id>`，让落盘的副本真正接管播放。
  /// - 无内嵌源码：仅当 `asset:` / `asset` 指向的包内资源仍在时才可恢复
  ///   （源码走资源包）；否则返回 null，调用方记失败、不注册。
  Future<PluginConfig?> _resolvePyConfig(
    PluginConfig config,
    Map<String, dynamic> entry,
  ) async {
    final code = entry['pySource'] as String?;
    if (code != null && code.isNotEmpty) {
      await _savePySource(config.id, code);
      final engine = config.spiderEngine;
      if (engine == null) return config;
      final ref = engine.sourceRef ?? '';
      if (ref.startsWith('file:')) return config;
      if (ref.startsWith('asset:')) {
        final path = ref.substring('asset:'.length);
        if (await _assetExistsCached(path)) return config;
        return _withSourceRef(config, engine, 'file:${config.id}');
      }
      final asset = engine.asset;
      if (asset != null &&
          asset.isNotEmpty &&
          await _assetExistsCached(asset)) {
        return config;
      }
      return _withSourceRef(config, engine, 'file:${config.id}');
    }

    final engine = config.spiderEngine;
    final ref = engine?.sourceRef ?? '';
    final String? assetPath;
    if (ref.startsWith('asset:')) {
      assetPath = ref.substring('asset:'.length);
    } else {
      assetPath = engine?.asset;
    }
    if (assetPath == null ||
        assetPath.isEmpty ||
        !await _assetExistsCached(assetPath)) {
      return null;
    }
    return config;
  }

  PluginConfig _withSourceRef(
    PluginConfig config,
    SpiderEngineConfig engine,
    String sourceRef,
  ) =>
      config.copyWith(
        spiderEngine: SpiderEngineConfig(
          kind: engine.kind,
          asset: engine.asset,
          api: engine.api,
          ext: engine.ext,
          sourceRef: sourceRef,
        ),
      );

  /// 两份站点内容是否一致：配置规范化比对 + py 源码比对。
  ///
  /// 配置比对走 `fromJson(toJson())` 规范化，避免“同一份配置、不同构造
  /// 路径”造成的字段缺省差异误判为不同。py 站另比对源码全文：备份有源码
  /// 而本地读不到、或两边源码不同，都算内容不同（跳过不覆盖）。
  Future<bool> _isSameContent(
    PluginConfig existing,
    PluginConfig incoming,
    Map<String, dynamic> entry,
  ) async {
    if (_canonicalJson(existing) != _canonicalJson(incoming)) return false;
    if (!incoming.isPySource) return true;
    final backupCode = entry['pySource'] as String?;
    final currentCode = await _readPySource(existing);
    if (backupCode == null || backupCode.isEmpty) {
      return currentCode == null || currentCode.isEmpty;
    }
    return backupCode == currentCode;
  }

  String _canonicalJson(PluginConfig config) {
    try {
      return jsonEncode(
        PluginConfig.fromJson(config.toJson()).toJson(),
      );
    } catch (_) {
      return jsonEncode(config.toJson());
    }
  }

  static String _kindOf(PluginConfig config) {
    if (config.isJarSource) return 'jar';
    if (config.isPySource) return 'py';
    return 'json';
  }
}
