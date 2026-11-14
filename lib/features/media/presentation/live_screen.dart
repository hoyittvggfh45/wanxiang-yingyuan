/// 直播区：分组 + 频道列表，点频道进房间页播放。
///
/// 落在底部导航的「直播」目的地内。默认数据为内置 M3U 清单，
/// 支持导入自定义清单（选文件 / 粘贴文本）与恢复默认。
/// 点频道进 [LiveRoomScreen] 房间页（内嵌播放器 + 分组/频道列表 +
/// 全屏播放页），不直接推播放器页。
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/live/live_models.dart';
import '../../../core/live/live_repository.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../core/theme/app_tokens.dart';
import 'live_room_screen.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final LiveRepository _repo = LiveRepository();
  final TextEditingController _searchController = TextEditingController();
  Future<LiveParseResult>? _future;
  bool _usingCustom = false;
  String _selectedGroup = '';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = _repo.load();
    });
    unawaited(
      _repo.isUsingCustom().then((bool v) {
        if (mounted) setState(() => _usingCustom = v);
      }),
    );
  }

  List<LiveChannel> _visibleChannels(LiveParseResult result) {
    final List<LiveChannel> all = <LiveChannel>[];
    for (final LiveGroup g in result.groups) {
      if (_selectedGroup.isNotEmpty && g.name != _selectedGroup) continue;
      all.addAll(g.channels);
    }
    if (_query.isEmpty) return all;
    final String q = _query.toLowerCase();
    return all
        .where(
          (LiveChannel c) =>
              c.name.toLowerCase().contains(q) ||
              c.group.toLowerCase().contains(q),
        )
        .toList();
  }

  void _play(LiveParseResult result, LiveChannel channel) {
    if (!channel.playable) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该频道没有可用的播放地址')));
      return;
    }
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) =>
            LiveRoomScreen(result: result, initialChannel: channel),
      ),
    );
  }

  Future<void> _importFromFile() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['m3u', 'm3u8', 'txt'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final List<int>? bytes = picked.files.first.bytes;
    if (bytes == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('读取文件失败')));
      return;
    }
    await _applyCustomText(utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _importFromPaste() async {
    final TextEditingController controller = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('粘贴直播清单'),
        content: TextField(
          controller: controller,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '粘贴 M3U 或“频道名,地址”文本',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _applyCustomText(text);
  }

  Future<void> _applyCustomText(String text) async {
    try {
      await _repo.importCustom(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('自定义清单已导入')));
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _restoreDefault() async {
    await _repo.restoreDefault();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已恢复内置清单')));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceMd,
            0,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: '搜索频道',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (String v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              IconButton(
                icon: const Icon(Icons.file_upload_outlined),
                tooltip: '导入清单文件',
                onPressed: _importFromFile,
              ),
              IconButton(
                icon: const Icon(Icons.content_paste_rounded),
                tooltip: '粘贴清单',
                onPressed: _importFromPaste,
              ),
              if (_usingCustom)
                IconButton(
                  icon: const Icon(Icons.restore_rounded),
                  tooltip: '恢复内置清单',
                  onPressed: _restoreDefault,
                ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<LiveParseResult>(
            future: _future,
            builder: (BuildContext ctx, AsyncSnapshot<LiveParseResult> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError || !snap.hasData) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceLg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('直播清单加载失败：${snap.error}'),
                        const SizedBox(height: AppTokens.spaceMd),
                        FilledButton(
                          onPressed: _reload,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final LiveParseResult result = snap.data!;
              final List<LiveChannel> channels = _visibleChannels(result);
              return Column(
                children: <Widget>[
                  if (result.groups.length > 1)
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppTokens.spaceMd,
                          vertical: AppTokens.spaceSm,
                        ),
                        children: <Widget>[
                          ChoiceChip(
                            label: Text('全部（${result.totalChannels}）'),
                            selected: _selectedGroup.isEmpty,
                            onSelected: (_) =>
                                setState(() => _selectedGroup = ''),
                          ),
                          const SizedBox(width: AppTokens.spaceSm),
                          for (final LiveGroup g in result.groups) ...<Widget>[
                            ChoiceChip(
                              label: Text('${g.name}（${g.channels.length}）'),
                              selected: _selectedGroup == g.name,
                              onSelected: (_) =>
                                  setState(() => _selectedGroup = g.name),
                            ),
                            const SizedBox(width: AppTokens.spaceSm),
                          ],
                        ],
                      ),
                    ),
                  Expanded(
                    child: channels.isEmpty
                        ? const Center(child: Text('没有符合条件的频道'))
                        : ListView.builder(
                            itemCount: channels.length,
                            itemBuilder: (BuildContext ctx, int i) {
                              final LiveChannel c = channels[i];
                              return ListTile(
                                leading: c.logo != null && c.logo!.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(
                                          c.logo!,
                                          width: 40,
                                          height: 40,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(Icons.live_tv_rounded),
                                        ),
                                      )
                                    : const Icon(Icons.live_tv_rounded),
                                title: Text(c.name),
                                subtitle: Text(c.group),
                                trailing: c.urls.length > 1
                                    ? Text('${c.urls.length} 条地址')
                                    : null,
                                onTap: () => _play(result, c),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
