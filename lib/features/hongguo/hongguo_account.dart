/// 红果账号模型与本地存储（改写自火蚁TV hongguo_account.dart）。
///
/// 只用于红果身份展示：登录状态存在本地 SharedPreferences，不 gate 应用，
/// 不在启动链上初始化（设置页用到时才加载）。
///
/// 账号源 API（数据与帐户页的红果登入行与本文件共用同一份来源）：
/// - 状态：[hongguoAccountNotifier]（`HongguoAccount?`，null = 未登录）、
///   [HongguoAccount.loggedIn]、[hongguoAccountStatus]（枚举值）；
/// - 掩码标识：[HongguoAccount.maskPhone]（11 位手机号掩码）与
///   [HongguoAccount.maskedPhone] 字段；
/// - 退出登录：[clearHongguoAccount]（清存储 + 通知器置 null）。
/// 既有 API 签名保持不变，扩展只做加法。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HongguoAccount {
  const HongguoAccount({
    required this.userId,
    required this.displayName,
    this.maskedPhone = '',
    required this.method,
  });

  final String userId;
  final String displayName;
  final String maskedPhone;
  final String method;

  bool get loggedIn => userId.isNotEmpty;

  String get methodLabel => switch (method) {
        'sms' => '短信登录',
        'qr' => '扫码登录',
        _ => method,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'displayName': displayName,
        'maskedPhone': maskedPhone,
        'method': method,
      };

  factory HongguoAccount.fromJson(Map<String, dynamic> json) => HongguoAccount(
        userId: json['userId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        maskedPhone: json['maskedPhone'] as String? ?? '',
        method: json['method'] as String? ?? '',
      );

  static String maskPhone(String phone) {
    if (phone.length != 11) return phone;
    return '${phone.substring(0, 3)}****${phone.substring(7)}';
  }
}

/// 红果账号状态：未加载 / 未登录 / 已登录。
enum HongguoAccountStatus { unknown, loggedOut, loggedIn }

const hongguoAccountStorageKey = 'hongguoAccount';

final hongguoAccountNotifier = ValueNotifier<HongguoAccount?>(null);

bool _hongguoAccountLoaded = false;

/// 当前账号状态：存储未加载时为 unknown，加载后按通知器值区分。
HongguoAccountStatus get hongguoAccountStatus {
  if (!_hongguoAccountLoaded) return HongguoAccountStatus.unknown;
  final HongguoAccount? account = hongguoAccountNotifier.value;
  if (account == null || !account.loggedIn)
    return HongguoAccountStatus.loggedOut;
  return HongguoAccountStatus.loggedIn;
}

/// 是否已登录（存储未加载时为 false，调用方应先 await [ensureHongguoAccountLoaded]）。
bool get isHongguoLoggedIn =>
    hongguoAccountStatus == HongguoAccountStatus.loggedIn;

/// 账号展示标识：优先掩码手机号，其次显示名，最后“已登录账号”。
String hongguoAccountDisplayLabel([HongguoAccount? account]) {
  final HongguoAccount? current = account ?? hongguoAccountNotifier.value;
  if (current == null || !current.loggedIn) return '未登录';
  if (current.maskedPhone.isNotEmpty) return current.maskedPhone;
  if (current.displayName.isNotEmpty) return current.displayName;
  return '已登录账号';
}

Future<void> ensureHongguoAccountLoaded() async {
  if (_hongguoAccountLoaded) return;
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final String? raw = preferences.getString(hongguoAccountStorageKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        hongguoAccountNotifier.value = HongguoAccount.fromJson(decoded);
      }
    } on Object {
      // 损坏的本地账号记录忽略，视为未登录。
    }
  }
  _hongguoAccountLoaded = true;
}

Future<void> saveHongguoAccount(HongguoAccount account) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    hongguoAccountStorageKey,
    jsonEncode(account.toJson()),
  );
  hongguoAccountNotifier.value = account;
}

Future<void> clearHongguoAccount() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.remove(hongguoAccountStorageKey);
  hongguoAccountNotifier.value = null;
}
