VIDEO_SUFFIXES = (
    ".m3u8",
    ".mp4",
    ".mp3",
    ".flv",
    ".mkv",
    ".mov",
    ".ts",
    ".aac",
    ".m4a",
    ".webm",
)


def _norm_pg(value):
    try:
        page = int(value)
    except (TypeError, ValueError):
        return 1
    return page if page >= 1 else 1


def _norm_ids(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(item) for item in value]
    return [str(value)]


class BaseSpider:
    def __init__(self):
        self.extend = ""

    def getName(self):
        return ""

    def getDependence(self):
        return []

    def init(self, extend=""):
        if isinstance(extend, str):
            self.extend = extend
        else:
            self.extend = str(extend or "")
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=False):
        return {"class": [], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid="", pg=1, filter=False, extend=None):
        return {
            "list": [],
            "page": _norm_pg(pg),
            "pagecount": 1,
        }

    def detailContent(self, ids=None):
        return {"list": []}

    def searchContent(self, key="", quick=False, pg="1"):
        return {"list": [], "page": _norm_pg(pg)}

    def playerContent(self, flag="", id="", vipFlags=None):
        return {"parse": 0, "url": "", "header": {}}

    def localProxy(self, param=None):
        return [404, "text/plain", "localProxy not implemented", {}]

    def isVideoFormat(self, url=""):
        path = str(url or "").split("?")[0].split("#")[0].lower()
        return path.endswith(VIDEO_SUFFIXES)

    def manualVideoCheck(self):
        return False

    def action(self, action="", params=None):
        return ""
