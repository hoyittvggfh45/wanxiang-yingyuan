/// SM3 摘要算法的纯 Dart 实现。
///
/// 移植自火蚁TV Go 核 `provider_hongguo_comment_sign.go` 里的 `hongguoSM3`。
/// SM3 是公开标准算法（GB/T 32905），实现里不含任何密钥常量。
library;

/// 计算 [input] 的 SM3 摘要，返回 32 字节。
List<int> hongguoSm3(List<int> input) {
  final List<int> data = <int>[...input, 0x80];
  final int bitLength = input.length * 8;
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    data.add((bitLength >> (i * 8)) & 0xff);
  }
  final List<int> state = <int>[
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];
  for (int offset = 0; offset < data.length; offset += 64) {
    final List<int> words = List<int>.filled(68, 0);
    for (int i = 0; i < 16; i++) {
      words[i] = ((data[offset + i * 4] << 24) |
              (data[offset + i * 4 + 1] << 16) |
              (data[offset + i * 4 + 2] << 8) |
              data[offset + i * 4 + 3]) &
          0xffffffff;
    }
    for (int i = 16; i < 68; i++) {
      final int v = words[i - 16] ^ words[i - 9] ^ _rotl32(words[i - 3], 15);
      words[i] = (v ^
              _rotl32(v, 15) ^
              _rotl32(v, 23) ^
              _rotl32(words[i - 13], 7) ^
              words[i - 6]) &
          0xffffffff;
    }
    int a = state[0];
    int b = state[1];
    int c = state[2];
    int d = state[3];
    int e = state[4];
    int f = state[5];
    int g = state[6];
    int h = state[7];
    for (int i = 0; i < 64; i++) {
      final int t;
      final int ff;
      final int gg;
      if (i < 16) {
        t = 0x79cc4519;
        ff = a ^ b ^ c;
        gg = e ^ f ^ g;
      } else {
        t = 0x7a879d8a;
        ff = (a & b) | (a & c) | (b & c);
        gg = (e & f) | ((~e) & g);
      }
      final int ss1 = _rotl32(
        (_rotl32(a, 12) + e + _rotl32(t, i)) & 0xffffffff,
        7,
      );
      final int ss2 = ss1 ^ _rotl32(a, 12);
      final int tt1 = (ff + d + ss2 + (words[i] ^ words[i + 4])) & 0xffffffff;
      final int tt2 = (gg + h + ss1 + words[i]) & 0xffffffff;
      final int nextA = tt1;
      final int nextB = a;
      final int nextC = _rotl32(b, 9);
      final int nextD = c;
      final int nextE = (tt2 ^ _rotl32(tt2, 9) ^ _rotl32(tt2, 17)) & 0xffffffff;
      final int nextF = e;
      final int nextG = _rotl32(f, 19);
      final int nextH = g;
      a = nextA;
      b = nextB;
      c = nextC;
      d = nextD;
      e = nextE;
      f = nextF;
      g = nextG;
      h = nextH;
    }
    final List<int> round = <int>[a, b, c, d, e, f, g, h];
    for (int i = 0; i < 8; i++) {
      state[i] = (state[i] ^ round[i]) & 0xffffffff;
    }
  }
  final List<int> result = <int>[];
  for (final int value in state) {
    result.addAll(<int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }
  return result;
}

int _rotl32(int value, int bits) {
  final int v = value & 0xffffffff;
  final int n = bits & 31;
  return ((v << n) | (v >> (32 - n))) & 0xffffffff;
}

/// 字节转小写十六进制。
String hongguoHexEncode(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  for (final int byte in bytes) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
