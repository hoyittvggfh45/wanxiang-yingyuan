// Hive box 锁争用探针测试。
//
// 覆盖启动页永久卡死的修复机制：锁被占用时探针必须快速失败
// （抛 BoxLockContended），绝不能像 Hive.openBox 内部的阻塞锁那样
// 冻住事件循环；锁空闲时探针立即通过且不留锁。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/storage/box_lock_probe.dart';

void main() {
  test('锁空闲时探针立即通过，且可重复探（不留锁）', () async {
    final dir = await Directory.systemTemp.createTemp('probe_free_');
    try {
      await probeBoxLock(dir.path, 'sources');
      await probeBoxLock(dir.path, 'sources');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  // 争用只跨进程成立：Dart 的文件锁是 POSIX 语义，同进程内第二次拿锁
  // 必然成功（不争用），故持锁方必须是独立子进程。子进程用 PATH 上的
  // `dart` 启动（与 flutter 同目录，CI 与本机均有）；实在找不到时跳过。
  test('锁被另一进程占用时探针快速抛 BoxLockContended（2 秒内，不阻塞）',
      () async {
    final dir = await Directory.systemTemp.createTemp('probe_held_');
    Process? holder;
    try {
      final holderScript = File('${dir.path}/holder.dart');
      await holderScript.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final raf = await File(args[0]).open(mode: FileMode.write);
  await raf.lock();
  print('LOCKED');
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final lockPath = '${dir.path}/sources.lock';
      try {
        holder = await Process.start(
          'dart',
          [holderScript.path, lockPath],
          runInShell: false,
        );
      } on ProcessException {
        markTestSkipped('PATH 上找不到 dart，无法起子进程持锁');
      }
      // 等子进程报 LOCKED（确认锁已持有），最多等 10 秒。
      final locked = Completer<void>();
      holder!.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim() == 'LOCKED' && !locked.isCompleted) {
          locked.complete();
        }
      });
      await locked.future.timeout(const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      await expectLater(
        probeBoxLock(dir.path, 'sources'),
        throwsA(isA<BoxLockContended>()),
      );
      expect(sw.elapsedMilliseconds, lessThan(2000));
      // 持有进程退出后，探针恢复通过。
      holder.kill();
      await holder.exitCode;
      holder = null;
      await probeBoxLock(dir.path, 'sources');
    } finally {
      holder?.kill();
      await dir.delete(recursive: true);
    }
  });

  test('锁文件目录不存在时探针不挡路（交给 Hive 原有逻辑）', () async {
    await probeBoxLock('/definitely/not/a/real/dir/xyz', 'sources');
  });

  test('BoxLockContended 文案含盒子名与可操作指引', () {
    final text = const BoxLockContended('sources').toString();
    expect(text, contains('sources'));
    expect(text, contains('重试'));
  });
}
