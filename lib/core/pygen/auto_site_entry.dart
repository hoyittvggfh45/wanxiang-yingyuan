/// 网页爬取成功后自动进站点：模式门禁、生成结论判定与已注册站点
/// 查找（UI 无关，可单测）。
///
/// 自动链路只针对能生成视频站的爬取（视频 / 通用模式）；小说 / 漫画 /
// 文章模式保持现有查看行为，不自动转成视频站。去重按基址：同一基址
/// 已注册过（py 源码里含该基址）则直接打开已注册的那个，不重复生成、
/// 不重复建站。
library;

import '../models/plugin_config.dart';
import '../scraper/web_scrape_service.dart';
import '../services/source_repository.dart';
import '../spider/py_source_id.dart';
import '../spider/py_source_store.dart';
import 'onekey_py_service.dart';

/// 该爬取模式是否自动进站点：仅视频与通用模式。
bool isAutoEnterSiteMode(ScrapeMode mode) =>
    mode == ScrapeMode.video || mode == ScrapeMode.general;

/// 生成结论是否认得出结构：通用嗅探兜底不算认出，不自动建站
///（手动生成 / 导出 / 注册不受限）。
bool isRecognizedGeneration(OneKeyCodeResult gen) =>
    gen.templateId != OneKeyPyService.genericTemplateId;

/// 已注册站点查找结果。
class ExistingSiteCheck {
  const ExistingSiteCheck({this.active, this.inactive});

  /// 可直接打开的已注册源（在当前活跃源列表里）。
  final PluginConfig? active;

  /// 已注册但当前未激活（停用 / 隐藏 / 弃用 / 年龄拦截）：不能直接
  /// 打开，调用方须如实提示、不得静默跳转到别的源。
  final PluginConfig? inactive;

  bool get found => active != null || inactive != null;
}

/// 按基址查找已注册的 py 站点。
///
/// 候选 id 与生成注册同一推导（文件名 → id，含 `_py` 冲突后缀形态），
/// 再读其 py 源码确认含该基址（防同名不同站的 id 碰撞）。[readCode]
/// 可注入供测试，默认读真实存储。
Future<ExistingSiteCheck> checkExistingSiteForBase(
  SourceRepository repo,
  String base, {
  Future<String?> Function(PluginConfig source)? readCode,
}) async {
  if (base.isEmpty) return const ExistingSiteCheck();
  final String id =
      pySourceIdFromFileName('${OneKeyPyService.safeName(base)}.py');
  PluginConfig? candidate;
  for (final String cid in <String>[id, '${id}_py']) {
    final PluginConfig? found = repo.getById(cid);
    if (found != null && found.isPySource) {
      candidate = found;
      break;
    }
  }
  if (candidate == null) return const ExistingSiteCheck();
  final String? code =
      await (readCode ?? PySourceStore.readForSource)(candidate);
  if (code == null || !code.contains(base)) {
    return const ExistingSiteCheck();
  }
  final bool active = repo
      .byType(SourceType.animeSource)
      .any((PluginConfig c) => c.id == candidate!.id);
  if (active) return ExistingSiteCheck(active: candidate);
  return ExistingSiteCheck(inactive: candidate);
}

/// 自动进站决策。
enum AutoSiteAction {
  /// 直接打开已注册的源。
  openExisting,

  /// 该站已注册但未激活：提示用户去启用，不跳转。
  showInactiveNotice,

  /// 生成 py → 校验 → 注册 → 打开。
  generateAndOpen,

  /// 该模式不自动进站。
  skip,
}

/// 自动进站决策（模式门禁优先于去重结果）。
AutoSiteAction planAutoSiteEntry({
  required ScrapeMode mode,
  required ExistingSiteCheck existing,
}) {
  if (!isAutoEnterSiteMode(mode)) return AutoSiteAction.skip;
  if (existing.active != null) return AutoSiteAction.openExisting;
  if (existing.inactive != null) return AutoSiteAction.showInactiveNotice;
  return AutoSiteAction.generateAndOpen;
}
