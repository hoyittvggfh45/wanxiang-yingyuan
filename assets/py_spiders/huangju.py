try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import html as _html
import http.client
import http.cookiejar
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


SITE = 'https://huangju.net'
API = 'https://api.huangju.net'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
PAGE_SIZE = 30
SEARCH_SIZE = 20

SORT_CATS = [
    ('sort:recommend', '推荐'),
    ('sort:new', '最新'),
    ('sort:hot', '热门'),
]

FALLBACK_CATS = [
    ('adult', '成人'),
    ('mo-gai', '魔改'),
    ('romance', '爱情'),
    ('urban', '都市'),
    ('fantasy', '玄幻'),
    ('modern-romance', '现言'),
    ('brain-hole', '脑洞'),
    ('ancient-romance', '古言'),
    ('suspense', '悬疑'),
    ('chuan-yue', '穿越'),
    ('sweet-love', '甜宠'),
    ('qing-chun', '青春'),
]

_CAT_CACHE = None


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(str(s)).replace('\\/', '/').strip()


def _http_get(url, referer=None, timeout=45):
    h = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if referer:
        h['Referer'] = referer
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text:
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                return data.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(1)
    return ''


def _http_json(url, referer=None):
    raw = _http_get(url, referer=referer)
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except Exception:
        return None
    if isinstance(data, (dict, list)):
        return data
    return None


def _http_play(ep_id):
    url = '%s/play/%s' % (API, ep_id)
    h = {'User-Agent': UA, 'Accept': 'application/json', 'Referer': SITE + '/'}
    for _ in range(3):
        if _HAS_REQ:
            try:
                s = requests.Session()
                r = s.get(url, headers=h, timeout=45)
                if r.status_code == 200 and r.text:
                    data = json.loads(r.text)
                    play_url = _unescape(data.get('url') or '')
                    parts = []
                    for c in s.cookies:
                        if c.name.startswith('CloudFront-'):
                            parts.append('%s=%s' % (c.name, c.value))
                    return play_url, '; '.join(parts)
            except Exception:
                pass
        try:
            jar = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
            req = urllib.request.Request(url, headers=h)
            with opener.open(req, timeout=45, context=_ctx()) as resp:
                raw = resp.read().decode('utf-8', 'replace')
            data = json.loads(raw)
            play_url = _unescape(data.get('url') or '')
            parts = []
            for c in jar:
                if c.name.startswith('CloudFront-'):
                    parts.append('%s=%s' % (c.name, c.value))
            return play_url, '; '.join(parts)
        except Exception:
            pass
        time.sleep(1)
    return '', ''


def _parse_items(data):
    out = []
    if not isinstance(data, dict):
        return out
    items = data.get('items') or []
    seen = set()
    for it in items:
        if not isinstance(it, dict):
            continue
        did = it.get('id')
        slug = _unescape(it.get('slug') or '')
        if not did or not slug:
            continue
        vid = '%s-%s' % (slug, did)
        if vid in seen:
            continue
        title = _unescape(it.get('title') or '')
        if not title:
            continue
        seen.add(vid)
        pic = _unescape(it.get('coverUrl') or it.get('cover') or '')
        total = it.get('totalEpisodes') or 0
        try:
            total = int(total)
        except Exception:
            total = 0
        if total > 0:
            remarks = ('全 %s 集' % total) if (it.get('status') == 'completed') else ('更新至 %s 集' % total)
        else:
            remarks = ''
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_remarks': remarks,
        })
    return out


def _pagecount(total, size):
    try:
        total = int(total)
    except Exception:
        total = 0
    if total <= 0:
        return 0
    return (total + size - 1) // size


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
        return '剧果'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _cats(self):
        global _CAT_CACHE
        if _CAT_CACHE:
            return list(_CAT_CACHE)
        cats = []
        data = _http_json(API + '/categories', referer=SITE + '/')
        if isinstance(data, list):
            pool = []
            for c in data:
                if not isinstance(c, dict):
                    continue
                slug = _unescape(c.get('slug') or '')
                name = _unescape(c.get('name') or '')
                try:
                    count = int(c.get('dramaCount') or 0)
                except Exception:
                    count = 0
                if not slug or not name:
                    continue
                if count < 5 or len(name) > 6 or ',' in name or len(slug) > 20:
                    continue
                pool.append((count, slug, name))
            pool.sort(key=lambda x: -x[0])
            cats = [('cat:' + slug, name) for _, slug, name in pool[:40]]
        if not cats:
            cats = [('cat:' + slug, name) for slug, name in FALLBACK_CATS]
        _CAT_CACHE = list(SORT_CATS) + cats
        return list(_CAT_CACHE)

    def _catalog(self, tid, pg):
        pg = _norm_pg(pg)
        params = {'page': pg, 'pageSize': PAGE_SIZE}
        if tid.startswith('sort:'):
            kind = tid[5:]
            if kind in ('new', 'hot'):
                params['sort'] = kind
        elif tid.startswith('cat:'):
            params['category'] = tid[4:]
        else:
            params['category'] = tid
        url = '%s/dramas?%s' % (API, urllib.parse.urlencode(params))
        data = _http_json(url, referer=SITE + '/theater')
        if not data:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        items = _parse_items(data)
        total = data.get('total') or 0
        return {'list': items, 'page': pg, 'pagecount': _pagecount(total, PAGE_SIZE), 'total': total}

    def homeContent(self, filter=''):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)['list']
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in cats],
            'list': items,
        }

    def homeVideoContent(self):
        cats = self._cats()
        items = []
        if cats:
            items = self._catalog(cats[0][0], 1)['list']
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        return self._catalog(_norm_id(tid), pg)

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if not nid:
            return {'list': []}
        data = _http_json('%s/dramas/%s' % (API, urllib.parse.quote(nid, safe='-')), referer=SITE + '/')
        if not data:
            return {'list': []}
        title = _unescape(data.get('title') or '')
        if not title:
            return {'list': []}
        cat = data.get('category') or {}
        type_name = _unescape(cat.get('name') or '') if isinstance(cat, dict) else ''
        total = data.get('totalEpisodes') or 0
        try:
            total = int(total)
        except Exception:
            total = 0
        if total > 0:
            remarks = ('全 %s 集' % total) if (data.get('status') == 'completed') else ('更新至 %s 集' % total)
        else:
            remarks = ''
        pic = _unescape(data.get('coverUrl') or '')
        wide = _unescape(data.get('coverHUrl') or '')
        stills = [wide] if wide and wide != pic else []
        eps = data.get('episodes') or []
        playable = [e for e in eps if isinstance(e, dict) and e.get('playable') is not False and e.get('id')]
        if not playable:
            playable = [e for e in eps if isinstance(e, dict) and e.get('id')]
        links = []
        for e in playable:
            try:
                ep_no = int(e.get('epNo') or 0)
            except Exception:
                ep_no = 0
            label = e.get('title') or ''
            if not label:
                label = '第%s集' % ep_no if ep_no else '第%s集' % (len(links) + 1)
            links.append('%s$huangju:%s' % (_unescape(label), e.get('id')))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remarks,
            'vod_year': str(data.get('year') or ''),
            'vod_area': _unescape(data.get('region') or ''),
            'vod_content': _unescape(data.get('description') or ''),
            'type_name': type_name,
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(links),
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        params = {'q': key or '', 'page': pg, 'pageSize': SEARCH_SIZE}
        url = '%s/dramas?%s' % (API, urllib.parse.urlencode(params))
        data = _http_json(url, referer=SITE + '/search')
        if not data:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        items = _parse_items(data)
        total = data.get('total') or 0
        return {'list': items, 'page': pg, 'pagecount': _pagecount(total, SEARCH_SIZE), 'total': total}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('huangju:'):
            raw = raw[len('huangju:'):]
        ep_id = raw.strip()
        header = {'User-Agent': UA, 'Referer': SITE + '/'}
        m3u8 = ''
        cookie = ''
        if ep_id:
            m3u8, cookie = _http_play(ep_id)
        if cookie:
            header['Cookie'] = cookie
        return {'parse': 0, 'playUrl': m3u8, 'url': m3u8, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
