/// 听书在线浏览页。
///
/// 复用通用 [OnlineContentListScreen]，仅配置源类型与点击行为，不重复
/// 实现列表 UI（与小说/漫画在线页同一模式）。点作品进
/// [AudiobookDetailScreen]，不走统一详情页（统一详情页无听书分支）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:wxyy/core/local/local_content_actions.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/navigation/app_page_route.dart';
import 'package:wxyy/core/scraper/media_api_service.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/widgets/module_source_search_screen.dart';
import 'package:wxyy/core/widgets/online_content_list_screen.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_detail_screen.dart';
import 'package:wxyy/features/verification/presentation/verification_handler.dart';
import 'package:wxyy/generated/app_localizations.dart';

/// 听书在线浏览页。
class AudiobookOnlineListScreen extends StatelessWidget {
  const AudiobookOnlineListScreen({
    super.key,
    this.initialSource,
    this.onAddSource,
    this.onEnableRecommended,
  });

  final PluginConfig? initialSource;
  final VoidCallback? onAddSource;
  final VoidCallback? onEnableRecommended;

  @override
  Widget build(BuildContext context) {
    final SourceRepository repo = context.watch<SourceRepository>();
    final MediaApiService service = context.read<MediaApiService>();
    final List<PluginConfig> sources = repo.byType(SourceType.audioSource);
    final AppLocalizations l10n = AppLocalizations.of(context);

    return OnlineContentListScreen(
      title: 'audiobook',
      sources: sources,
      initialSource: initialSource,
      onAddSource: onAddSource,
      onEnableRecommended: onEnableRecommended,
      verificationHandler: handleVerificationRequest,
      emptyIcon: Icons.headphones_rounded,
      fetchItems: (PluginConfig source,
              {String? category,
              int page = 1,
              String? extractedUrl,
              String? renderedHtml,
              Map<String, String> vars = const <String, String>{}}) =>
          service.fetchApiResults(
        source,
        MediaApiService.routeForCategory(source, category),
        extractedUrl: extractedUrl,
        renderedHtml: renderedHtml,
        vars: <String, String>{
          'page': '$page',
          if (category != null) 'category': category,
          ...vars,
        },
      ),
      fetchCategories: service.fetchCategories,
      resolveHomeSections: service.resolveHomeSections,
      resolveFilters: service.resolveFilterGroups,
      onItemTap: (item, heroTag) => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => AudiobookDetailScreen(item: item, heroTag: heroTag),
        ),
      ),
      onSearch: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => ModuleSourceSearchScreen(
            sourceType: SourceType.audioSource,
            title: l10n.search,
            // 搜索结果含本地内容（导入/下载），本地条目直接进本地阅读器。
            onItemTap: (item, heroTag) => openSearchResultEntry(
              context,
              item: item,
              heroTag: heroTag,
              onOnline: (it, tag) => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => AudiobookDetailScreen(item: it, heroTag: tag),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
