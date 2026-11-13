import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/models/plugin_config.dart';

/// pms_javchu.json 配置层验收（v17，源库资产为准）。
///
/// 历史：v7 版测试按「javchu.com 已停放、源整体迁移到 hanime1.me」写
/// 期望；源库现行配置已演进到 v17 并迁回 javchu.com（源库索引
/// assets/source_library/index.json 登记 version 17、baseUrl
/// https://javchu.com，与本配置文件一致），v7 的迁移前提已过期。
/// 本测试按 v17 配置事实重写期望，配置本身未动；v7 落地的「筛选全走
/// tags 面 + 5 组同路由 + 12 版块」设计在 v17 里原样保留，继续锁定。
/// 验收用引擎真实的 PluginConfig.fromJson 消费交付物文件。
/// 注意：本测试只断言配置文件内容，不验证站点在线状态。
void main() {
  late PluginConfig source;

  const configPath = 'assets/source_library/sources/media/pms_javchu.json';

  setUpAll(() {
    final file = File(configPath);
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  String raw() => File(configPath).readAsStringSync();

  group('pms_javchu 独立源配置', () {
    test('基础块：独立 id、v17、javchu.com 主域、同构路由集', () {
      expect(source.id, 'pms_javchu');
      expect(source.version, 17);
      expect(source.type, SourceType.animeSource);
      expect(source.site.baseUrl, 'https://javchu.com');
      expect(source.site.domain, 'javchu.com');
      for (final r in const [
        'latest',
        'search',
        'detail',
        'episodes',
        'category',
        'video',
        'favorites',
        'favoritesAdd',
      ]) {
        expect(source.routes.containsKey(r), isTrue, reason: '路由 $r 就位');
      }
    });

    test('hosts：javchu.com 两条 + 图床 CDN 三条，全部启用', () {
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(hosts.length, 5, reason: '2 (javchu.com) + 3 (图床 CDN)');
      expect(hosts.every((h) => '${h.enabled}' == 'true'), isTrue);
      final byHost = <String, Set<String>>{};
      for (final h in hosts) {
        byHost.putIfAbsent('${h.host}', () => <String>{}).add('${h.ip}');
      }
      expect(byHost['javchu.com'], <String>{
        '172.67.187.141', '104.21.7.70',
      });
      expect(byHost['1497203185.rsc.cdn77.org'], <String>{
        '195.181.172.3', '195.181.172.6', '195.181.175.40',
      });
      // 旧 CF 快照 IP 与停放域 IP 一条都不能留。
      final ips = hosts.map((h) => '${h.ip}').toSet();
      for (final bad in const [
        '172.64.229.154', '162.159.0.1', '108.162.192.1',
        '172.64.33.1', '104.19.0.1', '2.59.170.20', '104.219.250.37',
      ]) {
        expect(ips.contains(bad), isFalse, reason: '过期/死域 IP $bad 已剔除');
      }
    });

    test('v17 无 bot UA：站点头用浏览器 UA，路由不声明 UA', () {
      expect(raw().contains('Dart/3.13'), isFalse,
          reason: 'bot UA 覆盖基础 UA → 与验证 WebView 的真实 UA 不一致，'
              'cf_clearance 会话失效，反复弹验证');
      expect(source.site.userAgent, anyOf(isNull, isEmpty));
      // 站点头声明的是浏览器 UA（非 Dart 冒充），且与验证 WebView 一致。
      final siteUa = source.site.headers?['User-Agent'] ?? '';
      expect(siteUa, contains('Mozilla/5.0'));
      expect(siteUa, contains('Chrome/'));
      expect(siteUa.contains('Dart'), isFalse);
      expect(source.antiHotlinking.userAgent, anyOf(isNull, isEmpty));
      for (final e in source.routes.entries) {
        final headers = e.value.headers;
        expect(headers?.containsKey('User-Agent') ?? false, isFalse,
            reason: '路由 ${e.key} 不应再声明 User-Agent');
      }
      // v17 未声明 antiHotlinking referer（空块），按配置事实锁定。
      expect(source.antiHotlinking.referer, anyOf(isNull, isEmpty));
    });

    test('域名一致性：mirrors/hosts/cookieDomains 全部指向 javchu.com', () {
      for (final m in source.site.mirrors) {
        expect(m.domain, 'javchu.com');
        expect(m.baseUrl, 'https://javchu.com');
      }
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(
        hosts.map((h) => '${h.host}').toSet(),
        <String>{'javchu.com', '1497203185.rsc.cdn77.org'},
      );
      final domains = source.network?.cookieDomains ?? const <String>[];
      expect(domains, <String>['javchu.com', '.javchu.com']);
      // v17 不再引用 hanime1.me 主域（评论登录态 cookie 键名
      // hanime1_session 是同平台 Laravel 会话键，不含该域名串）。
      expect(raw().contains('hanime1.me'), isFalse,
          reason: 'v17 已迁回 javchu.com，不再引用 hanime1.me');
    });

    test('评论/收藏链路同构落地', () {
      final comments = source.comments;
      expect(comments!.login!.url, 'https://javchu.com/login');
      // Laravel 会话键名同构（与 hanime 同平台共用同一 cookie jar 语义）。
      expect(comments.login!.checkCookie, 'hanime1_session');
      expect(comments.routes.containsKey('list'), isTrue);
      expect(comments.routes.containsKey('replies'), isTrue);
      final wf = source.webFavorite!;
      expect(wf.route, 'favorites');
      expect(wf.addRoute, 'favoritesAdd');
      expect(source.hasWebFavoriteBrowse, isTrue);
      expect(source.hasWebFavoriteAdd, isTrue);
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov['favList']?.type, 'script');
      expect(ov['folders']?.type, 'script');
      expect(ov['favoritesAdd']?.type, 'script');
    });

    test('筛选全走 tags 面：死 AV genre 值清零 + 5 组同路由声明（v7 设计保留）', () {
      // v7 拔掉的 6 个死 AV genre 值在 v17 里仍不存在。
      for (final dead in const [
        '日本AV', '素人業餘', '高清無碼', 'AI解碼', '國產AV', '國產素人',
      ]) {
        expect(raw().contains(dead), isFalse, reason: '死 AV 分类值已清：$dead');
      }
      // javchu 也不复用 hanime 的里番向 genre 值（走 tag 面）。
      for (final banned in const ['裏番', '泡麵番', 'Motion Anime', '新番預告']) {
        expect(raw().contains(banned), isFalse, reason: 'AV 源无此类型：$banned');
      }
      expect(source.version, 17);

      // 分类路由必须把 tag 值送进 tags[] 槽位。
      expect(source.routes['category']!.url, contains('tags[]={category}'),
          reason: '分类路由走 tags[] 槽位');
      expect(source.routes['category']!.url, isNot(contains('genre=')),
          reason: 'genre 槽位不再承接 tag 值');
      // v17 search 路由各参数均为可选形态（{x?}）；tags 走 tags[] 数组语义，
      // genre 槽位保留可选占位但无 genre 筛选组向其供值。
      expect(source.routes['search']!.url, contains('tags[]={tags?}'),
          reason: 'tags[] 重复参数数组语义');
      expect(raw().contains('&tags={tags}'), isFalse);

      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final byId = {for (final g in groups) g.id: g};
      // 无 genre 组（无任何活值可承载）。
      expect(byId.containsKey('genre'), isFalse);
      final tagGroup = byId['tags']!;
      expect(tagGroup.multiSelect, isTrue, reason: 'tags 面支持多选');
      final tagValues = tagGroup.options.map((o) => o.value).toSet();
      expect(tagValues, <String>{
        '無碼', '人妻', '風俗娘', '痴女', '痴漢', '調教', '性奴隸', '巨乳',
        '中文字幕',
      }, reason: '站点实测有结果的 AV 向 tag（各 59 卡）');
      // 分类 Tab 与 tags 组同值集（分类就是 tags 面的入口）。
      final catValues = source.category.categoryEntries
          .map((e) => e['id'])
          .toSet();
      expect(catValues, tagValues.difference(<String>{'中文字幕'}),
          reason: '8 个分类 = tags 组去掉中文字幕');
    });

    test('筛选分组全部声明 route=search（消除跨路由互斥清空）', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      expect(groups.length, 5, reason: 'tags/sort/date/duration/broad');
      for (final g in groups) {
        expect(g.route, 'search',
            reason: '分组 ${g.id} 必须声明 route，否则回落 category 与 tags 组'
                '跨路由互斥、互相清空已选项');
      }
      expect(source.filters!.route, 'search');
      final byId = {for (final g in groups) g.id: g};
      expect(byId['sort']!.options.map((o) => o.value).toSet().length, 9,
          reason: '站点排序 9 值');
      expect(byId['date']!.options.length, 6, reason: 'v7 新增日期面');
      expect(byId['duration']!.options.length, 8, reason: 'v7 新增时长面');
      expect(byId['broad']!.options.length, 2);
      // date/duration 值用站点繁体原文（实测 date=過去 24 小時 → 8 卡真过滤）。
      expect(byId['date']!.options.map((o) => o.value), contains('過去 24 小時'));
      expect(
          byId['duration']!.options.map((o) => o.value), contains('10 分鐘 +'));
    });

    test('homeSections：12 版块全部改用站点真实 tag/排序参数', () {
      final sections = source.homeSections;
      expect(sections.length, 12, reason: 'AV 分区 12 版块');
      expect(sections.every((s) => s.route == 'search'), isTrue);
      HomeSectionConfig sectionOf(String id) =>
          sections.firstWhere((x) => x.id == id);
      Map<String, Object> paramsOf(String id) => sectionOf(id).params;

      // 8 个 tag 版块逐一落地（tag 值实测各 59 卡）。
      const tagSections = <String, String>{
        'nomask': '無碼',
        'hitozuma': '人妻',
        'fuzoku': '風俗娘',
        'chijo': '痴女',
        'chikan': '痴漢',
        'kyoiku': '調教',
        'dorei': '性奴隸',
        'kyonyu': '巨乳',
      };
      for (final e in tagSections.entries) {
        expect(paramsOf(e.key)['tags'], e.value, reason: '版块 ${e.key}');
        expect(paramsOf(e.key)['sort'], '最新上傳');
        expect(paramsOf(e.key).containsKey('genre'), isFalse,
            reason: '版块不再走 genre 槽位');
      }
      expect(paramsOf('chinese-subtitle')['tags'], '中文字幕');
      expect(paramsOf('chinese-subtitle')['sort'], '最新上傳');
      expect(paramsOf('latest-release')['sort'], '最新上市');
      expect(paramsOf('latest-upload')['sort'], '最新上傳');
      expect(paramsOf('watching-now')['sort'], '他們在看');
      // 全部版块参数里不得再出现死 AV genre 值。
      for (final s in sections) {
        expect(s.params.containsKey('genre'), isFalse,
            reason: '版块 ${s.id} 不应有 genre 参数');
      }
    });
  });
}
