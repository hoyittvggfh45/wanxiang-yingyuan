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
import json
import re
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


API = 'https://api.sorani.cc/sorani-cms'
SITE = 'https://www.sorani.net'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
LINE = 'anime_jp_m3u8'

CATS = [
    ('1', 'TV番剧'),
    ('2', '剧场动画'),
    ('5', '特摄剧场'),
    ('7', '国漫'),
]


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(str(s)).strip()


def _http_get(url, referer=None, timeout=60):
    h = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
    if referer:
        h['Referer'] = referer
    for _ in range(2):
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


def _api(path):
    try:
        data = json.loads(_http_get(API + path, referer=SITE + '/'))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    if data.get('code') not in (200, 0, None) and not data.get('success', True):
        return None
    return data.get('data')


def _fix_pic(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return API + u
    return u


def _cards(records):
    out = []
    seen = set()
    for r in records or []:
        if not isinstance(r, dict):
            continue
        vid = r.get('id')
        if vid is None or vid in seen:
            continue
        title = _unescape(r.get('title'))
        if not title:
            continue
        seen.add(vid)
        remarks = _unescape(r.get('latestEpisodeLabel') or r.get('statusText') or '')
        out.append({
            'vod_id': str(vid),
            'vod_name': title,
            'vod_pic': _fix_pic(r.get('cover') or r.get('coverThumb') or ''),
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
        return '青空次元'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        data = _api('/api/video?page=%s&size=24&categoryId=%s&enabled=true&sortMode=latest&sortDesc=true' % (pg, tid))
        if not isinstance(data, dict):
            return [], pg, 0
        total = data.get('total') or 0
        try:
            pages = int(data.get('pages') or 0)
        except Exception:
            pages = 0
        if not pages and total:
            pages = (int(total) + 23) // 24
        return _cards(data.get('records')), pg, pages

    def homeContent(self, filter=''):
        items, _, _ = self._catalog(CATS[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items, _, _ = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items, _, pages = self._catalog(tid, pg)
        return {'list': items, 'page': pg, 'pagecount': pages, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if not nid:
            return {'list': []}
        data = _api('/api/video/%s' % urllib.parse.quote(nid))
        if not isinstance(data, dict):
            return {'list': []}
        title = _unescape(data.get('title'))
        if not title:
            return {'list': []}
        actors = []
        for a in data.get('actors') or []:
            if isinstance(a, dict) and a.get('actorName'):
                actors.append(_unescape(a.get('actorName')))
            if len(actors) >= 8:
                break
        eps = []
        for ep in data.get('episodes') or []:
            if not isinstance(ep, dict):
                continue
            eid = ep.get('episodeId')
            label = _unescape(ep.get('episodeLabel') or ep.get('title') or '')
            if eid is None or not label:
                continue
            eps.append('%s$qingkong:%s:%s' % (label, nid, eid))
        if not eps:
            latest = data.get('latestEpisodeId')
            label = _unescape(data.get('latestEpisodeLabel') or '第1集')
            if latest is not None:
                eps = ['%s$qingkong:%s:%s' % (label, nid, latest)]
        remarks = _unescape(data.get('latestEpisodeLabel') or '')
        status = _unescape(data.get('statusText') or '')
        if status and status not in remarks:
            remarks = (remarks + ' ' + status).strip() if remarks else status
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': _fix_pic(data.get('coverLarge') or data.get('cover') or ''),
            'vod_actor': ','.join(actors),
            'vod_director': _unescape(data.get('director')),
            'vod_remarks': remarks,
            'vod_year': _unescape(data.get('year')),
            'vod_area': _unescape(data.get('area')),
            'vod_content': _unescape(data.get('summary')),
            'type_name': _unescape(data.get('categoryName')),
            'vod_tag': _unescape(data.get('tags')),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        q = urllib.parse.quote(key or '')
        data = _api('/api/video?page=%s&size=24&keyword=%s&enabled=true&sortMode=relevance_popular&sortDesc=true' % (pg, q))
        if not isinstance(data, dict):
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        try:
            pages = int(data.get('pages') or 0)
        except Exception:
            pages = 0
        return {'list': _cards(data.get('records')), 'page': pg, 'pagecount': pages, 'total': data.get('total') or 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('qingkong:'):
            raw = raw[len('qingkong:'):]
        header = {'User-Agent': UA, 'Referer': SITE + '/'}
        parts = raw.split(':')
        if len(parts) < 2:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header}
        vid, eid = parts[0], parts[1]
        line = LINE
        lines = _api('/api/video/%s/play-lines' % urllib.parse.quote(vid))
        if isinstance(lines, list):
            for ln in lines:
                if isinstance(ln, dict) and ln.get('enable') and ln.get('code'):
                    line = ln.get('code')
                    break
        data = _api('/api/video/episode/%s/play?lineCode=%s' % (urllib.parse.quote(eid), urllib.parse.quote(line)))
        url = ''
        if isinstance(data, dict) and data.get('canPlay'):
            url = (data.get('playUrl') or '').strip()
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
