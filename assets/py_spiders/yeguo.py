try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import hashlib
import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


BASE = 'https://yeguodj.com'
API = 'https://yeguodj.com/api.php'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
API_KEY = b'2acf7e91e9864673'
API_IV = b'1c29882d3ddfcfd6'
SIGN_KEY = '5589d41f92a597d016b037ac37db243d'

CATS = [
    ('0', '全部'),
    ('7', '野果原创'),
    ('8', '真人短剧'),
    ('9', '魔改漫剧'),
    ('10', '网红改编'),
    ('11', 'PMV裸舞'),
]

_RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36)


def _gf_mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else (a << 1)
        b >>= 1
    return r


def _gf_pow(a, e):
    r = 1
    while e:
        if e & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        e >>= 1
    return r


def _make_sbox():
    s = []
    for i in range(256):
        inv = 0 if i == 0 else _gf_pow(i, 254)
        x = inv
        y = inv
        for _ in range(4):
            y = ((y << 1) | (y >> 7)) & 0xff
            x ^= y
        s.append((x ^ 0x63) & 0xff)
    return s


_SBOX = _make_sbox()
_INV_SBOX = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV_SBOX[_v] = _i


def _expand_key(key):
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= _RCON[i // 4 - 1]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    out = []
    for r in range(11):
        rk = []
        for c in range(4):
            rk.extend(w[r * 4 + c])
        out.append(rk)
    return out


def _add_rk(state, rk):
    return [state[i] ^ rk[i] for i in range(16)]


def _inv_shift_rows(s):
    o = [0] * 16
    for r in range(4):
        for c in range(4):
            o[r + 4 * c] = s[r + 4 * ((c - r) % 4)]
    return o


def _inv_sub_bytes(s):
    return [_INV_SBOX[b] for b in s]


def _inv_mix_columns(s):
    o = [0] * 16
    for c in range(4):
        a = s[4 * c:4 * c + 4]
        o[4 * c + 0] = _gf_mul(a[0], 14) ^ _gf_mul(a[1], 11) ^ _gf_mul(a[2], 13) ^ _gf_mul(a[3], 9)
        o[4 * c + 1] = _gf_mul(a[0], 9) ^ _gf_mul(a[1], 14) ^ _gf_mul(a[2], 11) ^ _gf_mul(a[3], 13)
        o[4 * c + 2] = _gf_mul(a[0], 13) ^ _gf_mul(a[1], 9) ^ _gf_mul(a[2], 14) ^ _gf_mul(a[3], 11)
        o[4 * c + 3] = _gf_mul(a[0], 11) ^ _gf_mul(a[1], 13) ^ _gf_mul(a[2], 9) ^ _gf_mul(a[3], 14)
    return o


def _aes128_cbc_decrypt(key, iv, data):
    if len(data) == 0 or len(data) % 16:
        return b''
    rks = _expand_key(key)
    out = bytearray()
    prev = iv
    for off in range(0, len(data), 16):
        blk = list(data[off:off + 16])
        s = _add_rk(blk, rks[10])
        for rnd in range(9, 0, -1):
            s = _inv_shift_rows(s)
            s = _inv_sub_bytes(s)
            s = _add_rk(s, rks[rnd])
            s = _inv_mix_columns(s)
        s = _inv_shift_rows(s)
        s = _inv_sub_bytes(s)
        s = _add_rk(s, rks[0])
        for i in range(16):
            out.append(s[i] ^ prev[i])
        prev = data[off:off + 16]
    if out:
        n = out[-1]
        if 1 <= n <= 16 and out[-n:] == bytes([n]) * n:
            out = out[:-n]
    return bytes(out)


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _check_sign(obj):
    sign = obj.get('sign')
    if not sign:
        return True
    parts = []
    for k in sorted(obj.keys()):
        if k in ('sign', '_ver'):
            continue
        v = obj.get(k)
        if v is None:
            continue
        if k == 'data':
            v = str(v).replace(' ', '+')
        parts.append('%s=%s' % (k, v))
    raw = '&'.join(parts) + SIGN_KEY
    digest = hashlib.sha256(raw.encode('utf-8')).hexdigest()
    return hashlib.md5(digest.encode('utf-8')).hexdigest() == sign


def _api_post(path, params, timeout=30):
    url = API + path
    body = urllib.parse.urlencode(params)
    headers = {
        'User-Agent': UA,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': BASE + '/',
        'Accept': 'application/json, text/plain, */*',
    }
    raw = ''
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.post(url, data=body, headers=headers, timeout=timeout)
                if r.status_code == 200 and r.text:
                    raw = r.text
                    break
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=body.encode('utf-8'), headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read().decode('utf-8', 'replace')
                break
        except Exception:
            pass
        time.sleep(1)
    if not raw:
        return None
    try:
        obj = json.loads(raw)
    except Exception:
        return None
    if obj.get('errcode') != 0:
        return None
    if not _check_sign(obj):
        return None
    data = obj.get('data')
    if not data or not isinstance(data, str):
        return None
    try:
        plain = _aes128_cbc_decrypt(API_KEY, API_IV, base64.b64decode(data.replace(' ', '+')))
        env = json.loads(plain.decode('utf-8'))
    except Exception:
        return None
    if not isinstance(env, dict):
        return None
    return env.get('data')


def _parse_list(items):
    out = []
    seen = set()
    for it in items or []:
        vid = it.get('video_id') or it.get('id')
        if vid is None:
            continue
        vid = str(vid)
        if not vid or vid in seen:
            continue
        title = (it.get('title') or '').strip()
        if not title:
            continue
        seen.add(vid)
        remarks = (it.get('play_count_text') or '').strip()
        status = (it.get('serialize_status_text') or '').strip()
        if status:
            remarks = (status + ' ' + remarks).strip() if remarks else status
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': it.get('cover') or '',
            'vod_remarks': remarks,
        })
    return out


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


class Spider(BaseSpider):
    def getName(self):
        return '野果短剧'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _home_list(self):
        data = _api_post('/api/home/homePage', {})
        if isinstance(data, dict):
            top = data.get('top_list') or []
            items = _parse_list(top)
            if items:
                return items
        data = _api_post('/api/theater/exploreList', {'page': 1})
        if isinstance(data, dict):
            return _parse_list(data.get('list') or [])
        return []

    def homeContent(self, filter=''):
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': self._home_list(),
        }

    def homeVideoContent(self):
        return {'list': self._home_list(), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        params = {'page': pg}
        if str(tid or '0') != '0':
            params['theme'] = str(tid)
        data = _api_post('/api/theater/exploreList', params)
        if not isinstance(data, dict):
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        total = data.get('total') or 0
        try:
            total = int(total)
        except Exception:
            total = 0
        limit = data.get('limit') or 30
        try:
            limit = int(limit)
        except Exception:
            limit = 30
        pagecount = (total + limit - 1) // limit if limit > 0 else 0
        return {
            'list': _parse_list(data.get('list') or []),
            'page': pg,
            'pagecount': pagecount,
            'total': total,
        }

    def detailContent(self, ids):
        vid = _norm_id(ids).strip().lstrip('/')
        if not vid:
            return {'list': []}
        data = _api_post('/api/playlet/detail', {'video_id': vid})
        if not isinstance(data, dict):
            return {'list': []}
        title = (data.get('title') or '').strip()
        if not title:
            return {'list': []}
        cover = data.get('cover') or ''
        social = data.get('social_cover') or ''
        eps = []
        for ep in data.get('episodes') or []:
            eid = ep.get('id')
            if eid is None:
                continue
            label = (ep.get('title') or '').strip()
            if not label:
                label = '第%s集' % (ep.get('sort') or '')
            eps.append('%s$yeguo:%s:%s' % (label, vid, eid))
        if not eps:
            return {'list': []}
        tags = data.get('tags') or []
        actors = data.get('actor_list') or []
        remarks = (data.get('serialize_status_text') or '').strip()
        pc = (data.get('play_count_text') or '').strip()
        if pc:
            remarks = (remarks + ' ' + pc).strip() if remarks else pc
        stills = []
        if social and social != cover:
            stills = [social]
        return {'list': [{
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': ', '.join([str(a) for a in actors]),
            'vod_director': '',
            'vod_remarks': remarks,
            'vod_year': '',
            'vod_area': '',
            'vod_content': data.get('description') or '',
            'type_name': '短剧',
            'vod_tag': ', '.join([str(t) for t in tags]),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        data = _api_post('/api/search/result', {'keyword': key or '', 'page': pg})
        if not isinstance(data, dict):
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        total = data.get('total') or 0
        try:
            total = int(total)
        except Exception:
            total = 0
        limit = data.get('limit') or 10
        try:
            limit = int(limit)
        except Exception:
            limit = 10
        pagecount = (total + limit - 1) // limit if limit > 0 else 0
        return {
            'list': _parse_list(data.get('list') or []),
            'page': pg,
            'pagecount': pagecount,
            'total': total,
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('yeguo:'):
            raw = raw[len('yeguo:'):]
        parts = raw.split(':')
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if len(parts) < 2:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        vid, eid = parts[0], parts[1]
        header['Referer'] = BASE + '/drama/video/%s/' % vid
        data = _api_post('/api/playlet/play', {'video_id': vid, 'episode_id': eid})
        url = ''
        if isinstance(data, dict):
            access = data.get('access') or {}
            if access.get('can_play'):
                url = data.get('video_url') or ''
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
