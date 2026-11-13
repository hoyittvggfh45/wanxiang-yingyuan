// 搜索热词解析单测：打包资源/缓存共用的 parseKeywordsJson 容错规则。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/search/hot_search_keywords.dart';

void main() {
  group('HotSearchKeywords.parseKeywordsJson', () {
    test('解析标准结构（按模块分组）', () {
      final raw = jsonEncode({
        'animeSource': ['进击的巨人', '咒术回战'],
        'mangaSource': ['海贼王'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['animeSource'], ['进击的巨人', '咒术回战']);
      expect(parsed['mangaSource'], ['海贼王']);
    });

    test('过滤空串与非字符串项', () {
      final raw = jsonEncode({
        'animeSource': ['  ', ' valid ', 123, null, 'ok'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['animeSource'], ['valid', 'ok']);
    });

    test('去重且保持出现顺序', () {
      final raw = jsonEncode({
        'novelSource': ['诡秘之主', '诡秘之主', ' 遮天 ', '遮天'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['novelSource'], ['诡秘之主', '遮天']);
    });

    test('单模块截断到上限', () {
      final raw = jsonEncode({
        'animeSource': List<String>.generate(
          HotSearchKeywords.maxKeywordsPerModule + 10,
          (i) => '词$i',
        ),
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(
        parsed['animeSource']!.length,
        HotSearchKeywords.maxKeywordsPerModule,
      );
    });

    test('非法 JSON / 非 Map / 空列表模块返回空表', () {
      expect(HotSearchKeywords.parseKeywordsJson('not json'), isEmpty);
      expect(HotSearchKeywords.parseKeywordsJson('[1,2,3]'), isEmpty);
      expect(
        HotSearchKeywords.parseKeywordsJson(jsonEncode({'animeSource': []})),
        isEmpty,
      );
    });
  });
}
