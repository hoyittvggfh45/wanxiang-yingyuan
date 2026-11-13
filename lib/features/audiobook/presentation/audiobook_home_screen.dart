/// 听书区首页：与小说/漫画首页同一套 [LibraryShell] 结构。
///
/// - 书架段：[BookshelfContent]（本地 / 历史 / 收藏三子段，按
///   [SourceType.audioSource] 过滤；历史与收藏由听书详情/播放页写入）；
/// - 在线段：[OnlineSourceBrowserScreen]（音频源列表，点源进在线浏览）；
/// - 源段：[SourceManagerScreen]（`filterType: audioSource` 嵌入模式，
///   导入/订阅/启用走源管理同一套，本页不另写源管理）。
///
/// 未接：RSS 订阅段（听书无订阅需求）、本地导入入口（本地音频尚无本地
/// 媒体种类映射，本地段待主执行人补齐种类分支后才有内容）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:wxyy/core/local/local_content_actions.dart';
import 'package:wxyy/core/models/bookshelf_filter.dart';
import 'package:wxyy/core/models/media_item.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/navigation/app_page_route.dart';
import 'package:wxyy/core/services/source_repository.dart';
import 'package:wxyy/core/widgets/bookshelf_content.dart';
import 'package:wxyy/core/widgets/library_shell.dart';
import 'package:wxyy/core/widgets/module_source_search_screen.dart';
import 'package:wxyy/core/widgets/online_source_browser_screen.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_detail_screen.dart';
import 'package:wxyy/features/audiobook/presentation/audiobook_online_list_screen.dart';
import 'package:wxyy/features/sources/presentation/collect_api_import_screen.dart';
import 'package:wxyy/features/sources/presentation/source_manager_screen.dart';
import 'package:wxyy/generated/app_localizations.dart';

/// 听书区首页（底部导航「听书」目的地）。
class AudiobookHomeScreen extends StatelessWidget {
  const AudiobookHomeScreen({super.key});

  void _openDetail(BuildContext context, MediaItem item, String? heroTag) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => AudiobookDetailScreen(item: item, heroTag: heroTag),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    void navigateToCollectApiImport() {
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => const CollectApiImportScreen(),
        ),
      );
    }

    return LibraryShell(
      title: l10n.tabLibrary,
      emptyIcon: Icons.headphones_rounded,
      emptyMessage: '暂无听书内容',
      onSearch: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => ModuleSourceSearchScreen(
            sourceType: SourceType.audioSource,
            title: l10n.search,
            // 搜索结果含本地内容（导入/下载），本地条目直接进本地阅读器，
            // 在线条目进听书详情页。
            onItemTap: (MediaItem item, String? heroTag) =>
                openSearchResultEntry(
              context,
              item: item,
              heroTag: heroTag,
              onOnline: (it, tag) => _openDetail(context, it, tag),
            ),
          ),
        ),
      ),
      libraryBodyBuilder: (LibrarySubTab subTab, BookshelfFilter filter) =>
          BookshelfContent(
        sourceType: SourceType.audioSource,
        subTab: subTab,
        filter: filter,
        emptyIcon: Icons.headphones_rounded,
        emptyMessage: '暂无听书内容',
        onItemTap: (MediaItem item) => _openDetail(context, item, null),
      ),
      onlineBody: OnlineSourceBrowserScreen(
        sourceType: SourceType.audioSource,
        emptyIcon: Icons.headphones_rounded,
        onAddSource: navigateToCollectApiImport,
        onEnableRecommended: () =>
            context.read<SourceRepository>().enableRecommendedSources(),
        onSourceTap: (PluginConfig source) => Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => AudiobookOnlineListScreen(
              initialSource: source,
              onAddSource: navigateToCollectApiImport,
              onEnableRecommended: () =>
                  context.read<SourceRepository>().enableRecommendedSources(),
            ),
          ),
        ),
      ),
      sourcesBody: const _AudiobookSourcesBody(
        filterType: SourceType.audioSource,
      ),
      categoryProvider: (LibrarySubTab subTab) =>
          BookshelfContent.categoriesFor(
        context,
        SourceType.audioSource,
        subTab,
      ),
      historySourceType: SourceType.audioSource,
      favoriteSourceType: SourceType.audioSource,
    );
  }
}

class _AudiobookSourcesBody extends StatelessWidget {
  final SourceType filterType;

  const _AudiobookSourcesBody({required this.filterType});

  @override
  Widget build(BuildContext context) {
    return SourceManagerScreen(
      filterType: filterType,
      embedded: true,
    );
  }
}
