/// 直播数据源：默认内置 M3U + 用户自导入清单（二选一）。
///
/// 默认数据为随包内置的 `assets/live/user_m3u.m3u`（魔蚁同款清单，
/// 随点随播的点播型条目为主）；用户导入自定义清单后优先用自定义，
/// 可随时恢复默认。解析失败时抛错，由界面显示诚实错误。
library;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_models.dart';
import 'live_parser.dart';

class LiveRepository {
  static const String defaultAsset = 'assets/live/user_m3u.m3u';
  static const String _customTextKey = 'live_custom_playlist_text_v1';
  static const String _useCustomKey = 'live_use_custom_playlist_v1';

  /// 当前生效的清单解析结果。
  Future<LiveParseResult> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool useCustom = prefs.getBool(_useCustomKey) ?? false;
    final String? custom = prefs.getString(_customTextKey);
    if (useCustom && custom != null && custom.trim().isNotEmpty) {
      final LiveParseResult result = LiveParser.parse(custom);
      if (result.isEmpty) {
        throw StateError('自定义清单里没有可识别的频道，请检查清单格式');
      }
      return result;
    }
    final String text = await rootBundle.loadString(defaultAsset);
    final LiveParseResult result = LiveParser.parse(text);
    if (result.isEmpty) {
      throw StateError('内置直播清单为空，请导入自定义清单');
    }
    return result;
  }

  /// 是否正在使用自定义清单。
  Future<bool> isUsingCustom() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_useCustomKey) ?? false) &&
        (prefs.getString(_customTextKey)?.trim().isNotEmpty ?? false);
  }

  /// 导入自定义清单文本（先校验可解析出频道，解析不出不保存）。
  Future<LiveParseResult> importCustom(String text) async {
    final LiveParseResult result = LiveParser.parse(text);
    if (result.isEmpty) {
      throw StateError('清单里没有可识别的频道，未保存');
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customTextKey, text);
    await prefs.setBool(_useCustomKey, true);
    return result;
  }

  /// 恢复使用内置默认清单（自定义文本保留，可再次启用）。
  Future<void> restoreDefault() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useCustomKey, false);
  }
}
