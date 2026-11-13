import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/features/hongguo/hongguo_account.dart';

void main() {
  group('HongguoAccount.maskPhone', () {
    test('11 位手机号前 3 后 4 中间星号', () {
      expect(HongguoAccount.maskPhone('13812345678'), '138****5678');
    });

    test('非 11 位原样返回', () {
      expect(HongguoAccount.maskPhone('123'), '123');
      expect(HongguoAccount.maskPhone(''), '');
    });
  });

  group('HongguoAccount 序列化', () {
    test('toJson/fromJson 往返一致', () {
      const account = HongguoAccount(
        userId: 'u123',
        displayName: '道友',
        maskedPhone: '138****5678',
        method: 'sms',
      );
      final restored = HongguoAccount.fromJson(account.toJson());
      expect(restored.userId, 'u123');
      expect(restored.displayName, '道友');
      expect(restored.maskedPhone, '138****5678');
      expect(restored.method, 'sms');
      expect(restored.loggedIn, isTrue);
    });

    test('空 userId 视为未登录', () {
      const account = HongguoAccount(
        userId: '',
        displayName: '',
        method: 'sms',
      );
      expect(account.loggedIn, isFalse);
    });

    test('methodLabel', () {
      expect(
        const HongguoAccount(
          userId: '1',
          displayName: '',
          method: 'sms',
        ).methodLabel,
        '短信登录',
      );
      expect(
        const HongguoAccount(
          userId: '1',
          displayName: '',
          method: 'qr',
        ).methodLabel,
        '扫码登录',
      );
    });
  });
}
