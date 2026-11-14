/// Hive box 锁争用探针（启动页专用）。
///
/// 背景：Hive 2.2.3 打开 box 时在 `<box>.lock` 上拿阻塞式排他文件锁
///（`RandomAccessFile.lock()`，默认 `FileLock.blockingExclusive`）。
/// 实测（Linux Dart VM）：锁被另一进程持有时，等待中的 `lock()` 会堵住
/// 整个事件循环——计时器一次也不触发、`Future.timeout` 永不生效。
/// 手机上表现为：退出重开后若旧引擎/进程滞留（容器内进程未真正退出，
/// 仍持有全部 box 锁），新进程启动时卡在加载页、加载点 frozen、45 秒
/// 超时界面永远出不来。
///
/// 本探针在 `Hive.openBox` 之前用**非阻塞**排他锁（`FileLock.exclusive`）
/// 试探同一把锁：被占用时 2ms 内快速失败（EAGAIN），绝不阻塞事件循环；
/// 探到争用就直接抛 [BoxLockContended]，让启动页显示真实原因 + 重试，
/// 而不是无声永久卡死。探针与 `Hive.openBox` 之间有极窄的竞态窗口
///（探完后瞬间冒出新持有者），残余风险可接受。
library;

import 'dart:io';

/// 某 box 的锁正被另一个活着的引擎/进程持有。
class BoxLockContended implements Exception {
  final String boxName;
  const BoxLockContended(this.boxName);

  @override
  String toString() =>
      '数据文件（$boxName）正被应用的上一次运行占用：旧进程没有完全退出。'
      '请先从最近任务里把应用划掉、彻底退出后，再点重试；'
      '如仍失败，请到系统设置里强行停止本应用后重开。';
}

/// 试探 [boxName] 的 Hive 锁文件是否可拿。
///
/// [hiveDir] 是 `Hive.initFlutter` 用的目录（应用文档目录）。
/// 锁空闲时立即返回；被占用时抛 [BoxLockContended]；探针自身遇到
/// 其它文件系统问题（目录不存在、文件系统不支持锁等）时静默返回，
/// 把处理权留给 `Hive.openBox` 原有逻辑，不因此多挡一次启动。
Future<void> probeBoxLock(String hiveDir, String boxName) async {
  final File lockFile =
      File('$hiveDir${Platform.pathSeparator}$boxName.lock');
  RandomAccessFile? raf;
  try {
    raf = await lockFile.open(mode: FileMode.write);
    try {
      await raf.lock(FileLock.exclusive);
    } on FileSystemException catch (e) {
      // 非阻塞拿锁失败：EAGAIN(11)/EACCES(13) 是 POSIX 锁争用，
      // 33 是 Windows 的锁冲突；其余错误（如文件系统不支持锁）
      // 不当争用处理，交给 Hive 原有逻辑。
      final int? code = e.osError?.errorCode;
      if (code == 11 || code == 13 || code == 33) {
        throw BoxLockContended(boxName);
      }
      return;
    }
    await raf.unlock();
  } on BoxLockContended {
    rethrow;
  } on FileSystemException {
    // 打开锁文件本身失败（目录缺失等）：交给 Hive.openBox 处理。
    return;
  } finally {
    try {
      await raf?.close();
    } on Object {
      // 关闭失败不影响探针结论。
    }
  }
}
