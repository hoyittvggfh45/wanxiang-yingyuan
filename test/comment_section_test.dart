/// 评论区 Widget 测试（计划 §测试 6）。
///
/// - 源未配置 comments → 详情页骨架不渲染任何评论元素。
/// - 声明 post 路由 → 显示「写评论」（无登录门禁）。
/// - routes 缺 like/report → 对应按钮不渲染。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/comments/comment_api_service.dart';
import 'package:wxyy/core/models/plugin_config.dart';
import 'package:wxyy/core/network/model/effective_network_profile.dart';
import 'package:wxyy/core/widgets/comment_section.dart';
import 'package:wxyy/core/widgets/content_detail_shell.dart';
import 'package:wxyy/generated/app_localizations.dart';

/// 队列式 fake HTTP 客户端（与 comment_api_service_test 同款）。
class FakeCommentClient implements CommentHttpClient {
  final List<Object> responses = <Object>[];

  void enqueue(Object response) => responses.add(response);

  Future<String> _pop() {
    if (responses.isEmpty) {
      throw StateError('FakeCommentClient: no queued response');
    }
    final next = responses.removeAt(0);
    if (next is Exception) return Future<String>.error(next);
    return Future<String>.value(next as String);
  }

  @override
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      _pop();

  @override
  Future<String> postText(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      _pop();

  @override
  Future<String> postFormText(
    String url, {
    Map<String, String>? headers,
    Map<String, String>? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      _pop();
}

PluginConfig buildSource({Map<String, dynamic>? comments}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1',
      'name': 'S',
      'type': 'animeSource',
      'site': {'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {
        'latest': {'url': '/latest?page={page}'},
      },
      if (comments != null) 'comments': comments,
    });

/// 完整声明（list/post/reply/like/report + login）。
Map<String, dynamic> fullComments() => <String, dynamic>{
      'routes': {
        'list': {'url': '/api/comments?id={id}&page={page}'},
        'post': {
          'url': '/api/comments',
          'method': 'POST',
          'params': {'id': '{id}', 'content': '{text}'},
        },
        'reply': {
          'url': '/api/reply',
          'method': 'POST',
          'params': {'parent': '{commentId}', 'content': '{text}'},
        },
        'like': {'url': '/api/comments/{commentId}/like', 'method': 'POST'},
        'report': {
          'url': '/api/comments/{commentId}/report',
          'method': 'POST',
        },
      },
      'selectors': _selectors,
      'login': {
        'url': 'https://example.com/login',
        'checkCookie': 'user_token',
      },
    };

/// 只读声明（仅 list 路由，无发布/点赞/回复/举报）。
Map<String, dynamic> readonlyComments() => <String, dynamic>{
      'routes': {
        'list': {'url': '/api/comments?id={id}&page={page}'},
      },
      'selectors': _selectors,
      'login': {
        'url': 'https://example.com/login',
        'checkCookie': 'user_token',
      },
    };

const Map<String, dynamic> _selectors = <String, dynamic>{
  'items': r'$.data.list',
  'commentId': r'$.id',
  'author': r'$.user.name',
  'content': r'$.content',
  'time': r'$.time',
  'likeCount': r'$.likes',
  'replyCount': r'$.replyCount',
  'hasMore': r'$.data.hasMore',
};

String listBody({List<Map<String, dynamic>>? list, bool hasMore = false}) =>
    jsonEncode(<String, dynamic>{
      'data': {
        'hasMore': hasMore,
        'list': list ??
            <Map<String, dynamic>>[
              {
                'id': 101,
                'user': {'name': '甲'},
                'content': '好看',
                'time': '2小时前',
                'likes': 12,
                'replyCount': 0,
              },
            ],
      },
    });

Widget wrap({required Widget child}) =>
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('源未配置 comments 时详情页骨架不渲染任何评论元素',
      (WidgetTester tester) async {
    final source = buildSource(); // 无 comments 段
    await tester.pumpWidget(
      wrap(
        child: SizedBox(
          height: 600,
          child: ContentDetailShell(
            title: '测试作品',
            chaptersList: const SizedBox.shrink(),
            // 详情页接线逻辑：source.comments == null → 不注入评论区。
            commentsSection: source.comments != null
                ? CommentSection(source: source, contentId: 'c1')
                : null,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CommentSection), findsNothing);
    expect(find.text('登录后评论'), findsNothing);
    expect(find.text('写评论'), findsNothing);
  });

  testWidgets('声明 post 路由时显示「写评论」（无登录门禁）', (WidgetTester tester) async {
    final source = buildSource(comments: fullComments());
    final client = FakeCommentClient()..enqueue(listBody());
    await tester.pumpWidget(
      wrap(
        child: CommentSection(
          source: source,
          contentId: 'c1',
          service: CommentApiService(client: client),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('写评论'), findsOneWidget);
    expect(find.text('登录后评论'), findsNothing);
    // 首页评论正常可见。
    expect(find.text('好看'), findsOneWidget);
  });

  testWidgets('routes 缺 like/reply/report 时对应按钮不渲染',
      (WidgetTester tester) async {
    const comment = SourceComment(
      id: '101',
      author: '甲',
      content: '好看',
      timeText: '2小时前',
      likeCount: 12,
    );

    // 只读源：无 like/reply/report → 操作按钮全部不渲染。
    await tester.pumpWidget(
      wrap(
        child: CommentTile(
          source: buildSource(comments: readonlyComments()),
          comment: comment,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
    expect(find.byIcon(Icons.chat_bubble_rounded), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);

    // 完整源：like/reply/report 全声明 → 按钮渲染。
    await tester.pumpWidget(
      wrap(
        child: CommentTile(
          source: buildSource(comments: fullComments()),
          comment: comment,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
  });

  testWidgets('空评论时显示「发表第一条评论」', (WidgetTester tester) async {
    final source = buildSource(comments: fullComments());
    final client = FakeCommentClient()
      ..enqueue(listBody(list: <Map<String, dynamic>>[]));
    await tester.pumpWidget(
      wrap(
        child: CommentSection(
          source: source,
          contentId: 'c1',
          service: CommentApiService(client: client),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('暂无评论'), findsOneWidget);
    expect(find.text('发表第一条评论'), findsOneWidget);
  });
}
