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


BASE = 'https://guipianwu.com'
UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36'
PAGE_SIZE = 24

CATS = [
    ('3', '恐怖片'),
    ('6', '大陆鬼片'),
    ('7', '日韩鬼片'),
    ('8', '林正英鬼片'),
    ('9', '港台鬼片'),
    ('10', '泰国鬼片'),
    ('11', '欧美鬼片'),
    ('31', '剧情片'),
    ('12', '国产剧'),
    ('13', '美剧'),
    ('14', '韩剧'),
    ('15', '日剧'),
    ('16', '泰剧'),
    ('17', '港台剧'),
    ('18', '其他剧'),
    ('23', '日韩动漫'),
    ('24', '国产动漫'),
    ('25', '欧美动漫'),
    ('26', '港台动漫'),
]

MAIN_LIST_RE = re.compile(r'<ul class="row video-list video-film-list[^"]*">(.*?)</ul>', re.S)
CARD_RE = re.compile(r'<a class="video-link" href="/nv/(\d+)\.html"[^>]*title="([^"]*)"(.*?)</a>', re.S)
COVER_RE = re.compile(r'data-(?:original|background)="([^"]+)"')
REMARK_RE = re.compile(r'<div class="video-duration">(.*?)</div>', re.S)
TITLE_RE = re.compile(r'<h1 class="media-title[^"]*">(.*?)</h1>', re.S)
TITLE_TAG_RE = re.compile(r'<title>(.*?)</title>', re.S)
PIC_RE = re.compile(r'<div class="detail-img"><img[^>]+src="([^"]+)"')
PIC2_RE = re.compile(r'<div class="detail-cover[^"]*"[^>]*data-original="([^"]+)"')
DESC_RE = re.compile(r'简介：(.*?)</li>', re.S)
YEAR_RE = re.compile(r'年份：<span>(.*?)</span>')
DIRECTOR_RE = re.compile(r'导演：(.*?)</span>')
ACTOR_RE = re.compile(r'主演：(.*?)</span>', re.S)
AREA_RE = re.compile(r'地区：<span><a[^>]*>(.*?)</a>')
STATUS_RE = re.compile(r'状态：(.*?)</span>')
ANCHOR_RE = re.compile(r'<a[^>]*>([^<]+)</a>')
TAB_RE = re.compile(r'<li class="swiper-slide ewave-tab[^"]*" data-target="#(ewave-playlist-\d+)">([^<]+)</li>')
EP_RE = re.compile(r"<li><a title='([^']*)' href='([^']+)'")
NOW_RE = re.compile(r'''var\s+now\s*=\s*["']([^"']+)["']''')
MEDIA_RE = re.compile(r'''https?://[^"'\s<>\\]+\.(?:m3u8|mp4)(?:\?[^"'\s<>\\]*)?''', re.I)
PLAY_HREF_RE = re.compile(r"href='(/play/\d+-\d+-\d+\.html)'")
RSS_ITEM_RE = re.compile(r'<item>(.*?)</item>', re.S)
RSS_TITLE_RE = re.compile(r'<title>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</title>', re.S)
RSS_LINK_RE = re.compile(r'/nv/(\d+)\.html')
RSS_AUTHOR_RE = re.compile(r'<author>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</author>', re.S)
RSS_DESC_RE = re.compile(r'<description>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</description>', re.S)
TAG_RE = re.compile(r'<[^>]+>')


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).replace('\\/', '/').strip()


def _clean(s):
    if not s:
        return ''
    s = TAG_RE.sub('', s)
    s = _unescape(s)
    return ' '.join(s.replace('　', ' ').split())


def _http_get(url, referer=None, timeout=40):
    h = {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept-Encoding': 'gzip, deflate'}
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


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return u


def _parse_cards(html):
    seg = html or ''
    m = MAIN_LIST_RE.search(seg)
    if m:
        seg = m.group(1)
    out = []
    seen = set()
    for cm in CARD_RE.finditer(seg):
        vid = cm.group(1).strip()
        if not vid or vid in seen:
            continue
        title = _clean(cm.group(2))
        if not title:
            continue
        seen.add(vid)
        chunk = cm.group(3)
        cov = COVER_RE.search(chunk)
        rem = REMARK_RE.search(chunk)
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(cov.group(1)) if cov else '',
            'vod_remarks': _clean(rem.group(1)) if rem else '',
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
        return '鬼片网'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _catalog(self, tid, pg):
        if pg <= 1:
            url = '%s/list/%s.html' % (BASE, tid)
        else:
            url = '%s/list/%s_%s.html' % (BASE, tid, pg)
        return _parse_cards(_http_get(url, referer=BASE + '/'))

    def homeContent(self, filter=''):
        items = self._catalog(CATS[0][0], 1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items = self._catalog(CATS[0][0], 1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        items = self._catalog(_norm_id(tid), pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        nid = _norm_id(ids).strip().lstrip('/')
        if not nid:
            return {'list': []}
        detail_url = '%s/nv/%s.html' % (BASE, nid)
        html = _http_get(detail_url, referer=BASE + '/')
        if not html:
            return {'list': []}
        tm = TITLE_RE.search(html)
        title = _clean(tm.group(1)) if tm else ''
        if not title:
            tm = TITLE_TAG_RE.search(html)
            if tm:
                raw = _clean(tm.group(1))
                if '提示信息' in raw or '影片不存在' in raw:
                    return {'list': []}
                mm = re.search(r'《(.*?)》', raw)
                title = mm.group(1) if mm else raw
        if not title:
            return {'list': []}
        dm = DESC_RE.search(html)
        synopsis = _clean(dm.group(1)) if dm else ''
        pm = PIC_RE.search(html)
        if not pm:
            pm = PIC2_RE.search(html)
        pic = _fix_url(pm.group(1)) if pm else ''
        ym = YEAR_RE.search(html)
        year = _clean(ym.group(1)) if ym else ''
        dm2 = DIRECTOR_RE.search(html)
        director = _clean(dm2.group(1)) if dm2 else ''
        am = ACTOR_RE.search(html)
        actor = ''
        if am:
            names = [ _clean(a.group(1)) for a in ANCHOR_RE.finditer(am.group(1)) ]
            names = [n for n in names if n]
            actor = ' '.join(names) if names else _clean(am.group(1))
        rm = AREA_RE.search(html)
        area = _clean(rm.group(1)) if rm else ''
        sm = STATUS_RE.search(html)
        status = _clean(sm.group(1)) if sm else ''
        tabs = TAB_RE.findall(html)
        play_from = []
        play_groups = []
        seen_anchor = set()
        for anchor, name in tabs:
            if not anchor or anchor in seen_anchor:
                continue
            seen_anchor.add(anchor)
            marker = 'id="%s"' % anchor
            start = html.find(marker)
            if start < 0:
                continue
            seg = html[start + len(marker):]
            end = seg.find('<div class="playlist-slide')
            if end >= 0:
                seg = seg[:end]
            else:
                end = seg.find('</section>')
                if end >= 0:
                    seg = seg[:end]
            eps = []
            seen_path = set()
            for ep_title, href in EP_RE.findall(seg):
                href = href.strip()
                if not href or href in seen_path:
                    continue
                seen_path.add(href)
                label = _clean(ep_title) or '正片'
                eps.append('%s$guipian:%s' % (label, _fix_url(href)))
            if eps:
                play_from.append(_clean(name) or '在线播放')
                play_groups.append('#'.join(eps))
        if not play_groups:
            hrefs = []
            seen_path = set()
            for href in PLAY_HREF_RE.findall(html):
                if href not in seen_path:
                    seen_path.add(href)
                    hrefs.append(href)
            if hrefs:
                eps = ['%s$guipian:%s' % (('第%s集' % (i + 1)), _fix_url(href)) for i, href in enumerate(hrefs)]
                play_from.append('在线播放')
                play_groups.append('#'.join(eps))
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': actor,
            'vod_director': director,
            'vod_remarks': status,
            'vod_year': year,
            'vod_area': area,
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '$$$'.join(play_from),
            'vod_play_url': '$$$'.join(play_groups),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or '').strip()
        if not key:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        xml = _http_get(BASE + '/xml/rss.xml', referer=BASE + '/')
        matched = []
        seen = set()
        needle = key.lower()
        for im in RSS_ITEM_RE.finditer(xml or ''):
            seg = im.group(1)
            tm = RSS_TITLE_RE.search(seg)
            lm = RSS_LINK_RE.search(seg)
            if not tm or not lm:
                continue
            title = _clean(tm.group(1))
            vid = lm.group(1)
            if not title or not vid or vid in seen:
                continue
            if needle not in title.lower():
                continue
            seen.add(vid)
            am = RSS_AUTHOR_RE.search(seg)
            dm = RSS_DESC_RE.search(seg)
            matched.append({
                'vod_id': vid,
                'vod_name': title,
                'vod_pic': '',
                'vod_actor': _clean(am.group(1)) if am else '',
                'vod_content': _clean(dm.group(1)) if dm else '',
                'vod_remarks': '',
            })
        start = (pg - 1) * PAGE_SIZE
        page_items = matched[start:start + PAGE_SIZE]
        return {'list': page_items, 'page': pg, 'pagecount': 0, 'total': len(matched)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('guipian:'):
            raw = raw[len('guipian:'):]
        url = _fix_url(raw)
        header = {'User-Agent': UA, 'Referer': url}
        m3u8 = ''
        play_html = _http_get(url, referer=BASE + '/')
        if play_html:
            nm = NOW_RE.search(play_html)
            if nm:
                m3u8 = _unescape(nm.group(1))
            if not m3u8:
                mm = MEDIA_RE.search(play_html)
                if mm:
                    m3u8 = mm.group(0)
        if m3u8.startswith('//'):
            m3u8 = 'https:' + m3u8
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
