/// 听书胶囊与锁屏会话单测：显隐纯决策、胶囊内容模型、后台会话字段。
///
/// 不碰平台通道（原生胶囊与通知栏须真机验，此处只测 Dart 侧决策与模型）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wxyy/core/player/audio_playback_service.dart';
import 'package:wxyy/core/player/audiobook_capsule.dart';

void main() {
  group('AudiobookCapsulePolicy.shouldShow', () {
    test('shows only when backgrounded, playing, permitted and supported',
        () {
      expect(
        AudiobookCapsulePolicy.shouldShow(
          backgrounded: true,
          playing: true,
          permitted: true,
          supported: true,
        ),
        isTrue,
      );
    });

    test('hidden in foreground', () {
      expect(
        AudiobookCapsulePolicy.shouldShow(
          backgrounded: false,
          playing: true,
          permitted: true,
          supported: true,
        ),
        isFalse,
      );
    });

    test('hidden when paused', () {
      expect(
        AudiobookCapsulePolicy.shouldShow(
          backgrounded: true,
          playing: false,
          permitted: true,
          supported: true,
        ),
        isFalse,
      );
    });

    test('hidden without overlay permission (honest degrade)', () {
      expect(
        AudiobookCapsulePolicy.shouldShow(
          backgrounded: true,
          playing: true,
          permitted: false,
          supported: true,
        ),
        isFalse,
      );
    });

    test('hidden on unsupported platforms', () {
      expect(
        AudiobookCapsulePolicy.shouldShow(
          backgrounded: true,
          playing: true,
          permitted: true,
          supported: false,
        ),
        isFalse,
      );
    });
  });

  group('AudiobookCapsulePolicy.needsUpdate', () {
    const AudiobookCapsuleInfo shown = AudiobookCapsuleInfo(
      title: '第一章',
      artist: '某书',
      artUrl: 'https://x/cover.jpg',
      playing: true,
    );

    test('no update when nothing shown', () {
      expect(AudiobookCapsulePolicy.needsUpdate(null, shown), isFalse);
    });

    test('no update when identical', () {
      expect(AudiobookCapsulePolicy.needsUpdate(shown, shown), isFalse);
    });

    test('update on chapter change', () {
      expect(
        AudiobookCapsulePolicy.needsUpdate(
          shown,
          shown.copyWith(title: '第二章'),
        ),
        isTrue,
      );
    });

    test('update on playing state change', () {
      expect(
        AudiobookCapsulePolicy.needsUpdate(
          shown,
          shown.copyWith(playing: false),
        ),
        isTrue,
      );
    });
  });

  group('AudiobookCapsuleInfo', () {
    test('copyWith keeps untouched fields', () {
      const AudiobookCapsuleInfo info = AudiobookCapsuleInfo(
        title: '第一章',
        artist: '某书',
        playing: true,
      );
      final AudiobookCapsuleInfo next = info.copyWith(playing: false);
      expect(next.title, '第一章');
      expect(next.artist, '某书');
      expect(next.artUrl, isNull);
      expect(next.playing, isFalse);
    });

    test('equality covers all fields', () {
      const AudiobookCapsuleInfo a = AudiobookCapsuleInfo(
        title: '第一章',
        artist: '某书',
        artUrl: 'https://x/cover.jpg',
        playing: true,
      );
      const AudiobookCapsuleInfo b = AudiobookCapsuleInfo(
        title: '第一章',
        artist: '某书',
        artUrl: 'https://x/cover.jpg',
        playing: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == a.copyWith(artUrl: 'https://x/other.jpg'), isFalse);
    });
  });

  group('AudioPlaybackSession lock screen fields', () {
    test('artUri and album default to null (video/TTS sessions unchanged)',
        () {
      final AudioPlaybackSession session = AudioPlaybackSession(
        id: 'x::1',
        title: '第一集',
        artist: '某剧',
        playingStream: Stream<bool>.value(false),
        onPlay: () async {},
        onPause: () async {},
        onSeek: (_) async {},
      );
      expect(session.artUri, isNull);
      expect(session.album, isNull);
    });

    test('audiobook session carries cover artUri', () {
      final AudioPlaybackSession session = AudioPlaybackSession(
        id: 'src::c1',
        title: '第一章',
        artist: '某书',
        artUri: Uri.parse('https://x/cover.jpg'),
        playingStream: Stream<bool>.value(true),
        onPlay: () async {},
        onPause: () async {},
        onSeek: (_) async {},
      );
      expect(session.artUri.toString(), 'https://x/cover.jpg');
      expect(session.title, '第一章');
      expect(session.artist, '某书');
    });
  });
}
