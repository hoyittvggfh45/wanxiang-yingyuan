/// 听书章节列表（详情页与播放页的选集面板共用）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:wxyy/core/audiobook/audiobook_models.dart';
import 'package:wxyy/core/theme/app_tokens.dart';

/// 章节列表：序号圆标 + 标题 + 线路副标 + 已听/正在播状态。
///
/// [readIndices] 为已听章节下标集合；[currentIndex] 为正在播的章节下标
/// （详情页传 null，播放页传当前章）。点某章回调 [onChapterTap]，下标为
/// 过滤后列表的 0 起下标，与播放器章节下标一致。
class AudiobookChapterList extends StatelessWidget {
  const AudiobookChapterList({
    super.key,
    required this.chapters,
    required this.readIndices,
    required this.onChapterTap,
    this.currentIndex,
  });

  final List<AudiobookChapter> chapters;
  final Set<int> readIndices;
  final void Function(int index) onChapterTap;
  final int? currentIndex;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: chapters.length,
      itemBuilder: (BuildContext context, int i) {
        final AudiobookChapter chapter = chapters[i];
        final bool isCurrent = currentIndex == i;
        final bool isRead = readIndices.contains(i);
        final ColorScheme scheme = cs;
        return ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor:
                isCurrent ? scheme.primary : scheme.surfaceContainerHighest,
            foregroundColor:
                isCurrent ? scheme.onPrimary : scheme.onSurfaceVariant,
            child: Text(
              '${chapter.number}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          title: Text(
            chapter.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrent ? scheme.primary : null,
              fontWeight: isCurrent ? FontWeight.bold : null,
            ),
          ),
          subtitle: chapter.lineName == null
              ? null
              : Text(
                  chapter.lineName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: isCurrent
              ? Icon(Icons.equalizer_rounded, color: scheme.primary)
              : isRead
                  ? Icon(Icons.check_circle_rounded,
                      color: scheme.onSurfaceVariant)
                  : null,
          onTap: () => onChapterTap(i),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceMd,
          ),
        );
      },
    );
  }
}
