import base64
import hashlib
import inspect
import json
import math
import os
import ssl
import sys
import threading
import traceback
import types

try:
    _ssl_paths = ssl.get_default_verify_paths()
    _ssl_unverified = not (
        (_ssl_paths.cafile and os.path.exists(_ssl_paths.cafile))
        or (_ssl_paths.capath and os.path.exists(_ssl_paths.capath))
        or os.environ.get("SSL_CERT_FILE")
        or os.environ.get("SSL_CERT_DIR")
    )
except Exception:
    _ssl_unverified = False
if _ssl_unverified:
    ssl._create_default_https_context = ssl._create_unverified_context

CORE_METHODS = (
    "getName",
    "init",
    "homeContent",
    "homeVideoContent",
    "categoryContent",
    "detailContent",
    "searchContent",
    "playerContent",
)

DEFAULTED_METHODS = (
    "getDependence",
    "destroy",
    "localProxy",
    "isVideoFormat",
    "manualVideoCheck",
    "action",
)

ALL_METHODS = CORE_METHODS + DEFAULTED_METHODS

_instances = {}
_lock = threading.RLock()


def _jsonable(value):
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return None
        return value
    if isinstance(value, bytes):
        return {"$bytes": base64.b64encode(value).decode("ascii")}
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_jsonable(item) for item in value]
    return str(value)


def _default_is_video_format(url=None):
    path = str(url or "").split("?")[0].split("#")[0].lower()
    return path.endswith(
        (".m3u8", ".mp4", ".mp3", ".flv", ".mkv", ".mov", ".ts", ".aac", ".m4a", ".webm")
    )


_DEFAULT_IMPLS = {
    "getName": lambda: "",
    "getDependence": lambda: [],
    "init": lambda extend="": None,
    "destroy": lambda: None,
    "homeContent": lambda filter=False: {"class": [], "list": []},
    "homeVideoContent": lambda: {"list": []},
    "categoryContent": lambda tid="", pg=1, filter=False, extend=None: {
        "list": [],
        "page": _norm_pg(pg),
        "pagecount": 1,
    },
    "detailContent": lambda ids=None: {"list": []},
    "searchContent": lambda key="", quick=False, pg="1": {
        "list": [],
        "page": _norm_pg(pg),
    },
    "localProxy": lambda param=None: [
        404,
        "text/plain",
        "localProxy not implemented",
        {},
    ],
    "isVideoFormat": _default_is_video_format,
    "manualVideoCheck": lambda: False,
    "action": lambda action="", params=None: "",
}


def _norm_pg(value):
    try:
        page = int(value)
    except (TypeError, ValueError):
        return 1
    return page if page >= 1 else 1


def _fill_defaults(spider):
    filled = []
    for name, impl in _DEFAULT_IMPLS.items():
        if name == "playerContent":
            continue
        if not callable(getattr(spider, name, None)):
            setattr(spider, name, impl)
            filled.append(name)
    spider._wxyy_filled = filled
    return filled


class _RequestsResponse:
    def __init__(self, status, headers, body, url):
        self.status_code = status
        self.headers = headers
        self._body = body
        self.url = url

    @property
    def content(self):
        return self._body

    @property
    def text(self):
        return self._body.decode("utf-8", "ignore")

    def json(self):
        return json.loads(self.text)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError("HTTP %s" % self.status_code)


def _make_requests_module():
    import urllib.error
    import urllib.request

    def _request(method, url, **kwargs):
        headers = dict(kwargs.get("headers") or {})
        body = kwargs.get("data")
        payload = kwargs.get("json")
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")
        if isinstance(body, str):
            body = body.encode("utf-8")
        request = urllib.request.Request(
            url, data=body, headers=headers, method=method.upper()
        )
        try:
            with urllib.request.urlopen(
                request, timeout=kwargs.get("timeout")
            ) as response:
                return _RequestsResponse(
                    response.status,
                    dict(response.headers),
                    response.read(),
                    response.url,
                )
        except urllib.error.HTTPError as error:
            return _RequestsResponse(
                error.code, dict(error.headers), error.read(), url
            )

    class _Session:
        def __init__(self):
            self.headers = {}

        def request(self, method, url, **kwargs):
            merged = dict(self.headers)
            merged.update(kwargs.get("headers") or {})
            kwargs["headers"] = merged
            return _request(method, url, **kwargs)

        def get(self, url, **kwargs):
            return self.request("GET", url, **kwargs)

        def post(self, url, **kwargs):
            return self.request("POST", url, **kwargs)

        def head(self, url, **kwargs):
            return self.request("HEAD", url, **kwargs)

        def close(self):
            return None

    module = types.ModuleType("requests")
    module.get = lambda url, **kwargs: _request("GET", url, **kwargs)
    module.post = lambda url, **kwargs: _request("POST", url, **kwargs)
    module.head = lambda url, **kwargs: _request("HEAD", url, **kwargs)
    module.put = lambda url, **kwargs: _request("PUT", url, **kwargs)
    module.delete = lambda url, **kwargs: _request("DELETE", url, **kwargs)
    module.request = _request
    module.Session = _Session
    exceptions = types.ModuleType("requests.exceptions")

    class _RequestException(Exception):
        pass

    exceptions.RequestException = _RequestException
    exceptions.HTTPError = _RequestException
    exceptions.ConnectionError = _RequestException
    exceptions.Timeout = _RequestException
    module.exceptions = exceptions
    return module


def _ensure_requests():
    if "requests" in sys.modules:
        return False
    try:
        import requests
        return False
    except ImportError:
        pass
    sys.modules["requests"] = _make_requests_module()
    return True


def _ensure_base_spider():
    try:
        import base.spider
        return True
    except Exception:
        return False


def _load_spider(site_id, source, extend_text):
    digest = hashlib.md5(source.encode("utf-8")).hexdigest()
    cached = _instances.get(site_id)
    if cached is not None and cached["hash"] == digest:
        if cached["extend"] == extend_text:
            return cached["spider"]
        _dispose_locked(site_id)
    _ensure_base_spider()
    _ensure_requests()
    if source.startswith("\ufeff"):
        source = source[1:]
    module_name = "wxyy_spider_%s" % digest[:12]
    module = types.ModuleType(module_name)
    module.__dict__["__name__"] = module_name
    sys.modules[module_name] = module
    try:
        exec(compile(source, module_name + ".py", "exec"), module.__dict__)
    except Exception:
        sys.modules.pop(module_name, None)
        raise
    spider_class = getattr(module, "Spider", None)
    if spider_class is None:
        raise ImportError("源码中未找到 class Spider")
    spider = spider_class()
    _fill_defaults(spider)
    try:
        spider.init(extend_text)
    except TypeError:
        spider.init()
    _instances[site_id] = {
        "hash": digest,
        "extend": extend_text,
        "spider": spider,
        "module": module_name,
    }
    return spider


def _dispose_locked(site_id):
    cached = _instances.pop(site_id, None)
    if cached is None:
        return
    sys.modules.pop(cached["module"], None)
    try:
        cached["spider"].destroy()
    except Exception:
        pass


def _call_arity(func, args):
    try:
        params = list(inspect.signature(func).parameters.values())
    except (TypeError, ValueError):
        return func(*args)
    kinds = {
        inspect.Parameter.POSITIONAL_ONLY,
        inspect.Parameter.POSITIONAL_OR_KEYWORD,
    }
    positional = [p for p in params if p.kind in kinds]
    has_var = any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in params)
    if has_var or len(args) <= len(positional):
        return func(*args)
    return func(*args[: len(positional)])


def _as_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


def _as_str(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def _as_dict(value):
    if isinstance(value, dict):
        return value
    return {}


def _as_id_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(item) for item in value]
    return [str(value)]


def _as_vip_flags(args):
    flags = args.get("vipFlags")
    if isinstance(flags, (list, tuple)):
        return [str(item) for item in flags]
    single = _as_str(args.get("vipFlag"))
    if single:
        return [single]
    return []


def _dict_or_list(result):
    if isinstance(result, dict):
        return result
    return {"list": result}


def _dispatch(spider, method, args):
    if method == "getName":
        return str(spider.getName() or "")
    if method == "getDependence":
        return spider.getDependence()
    if method == "init":
        extend = args.get("extend", "")
        if not isinstance(extend, str):
            extend = json.dumps(extend, ensure_ascii=False, sort_keys=True)
        try:
            spider.init(extend)
        except TypeError:
            spider.init()
        return {}
    if method == "destroy":
        spider.destroy()
        return {}
    if method == "homeContent":
        result = _call_arity(spider.homeContent, (_as_bool(args.get("filter")),))
        return _dict_or_list(result)
    if method == "homeVideoContent":
        result = _call_arity(spider.homeVideoContent, ())
        return _dict_or_list(result)
    if method == "categoryContent":
        result = _call_arity(
            spider.categoryContent,
            (
                _as_str(args.get("tid")),
                _norm_pg(args.get("page", args.get("pg", 1))),
                _as_bool(args.get("filter")),
                _as_dict(args.get("extend", args.get("ext"))),
            ),
        )
        return _dict_or_list(result)
    if method == "detailContent":
        ids = _as_id_list(args.get("ids"))
        try:
            result = _call_arity(spider.detailContent, (ids,))
        except TypeError as first_error:
            try:
                result = spider.detailContent(ids[0] if ids else "")
            except TypeError:
                raise first_error
        return _dict_or_list(result)
    if method == "searchContent":
        result = _call_arity(
            spider.searchContent,
            (
                _as_str(args.get("keyword", args.get("key", ""))),
                _as_bool(args.get("quick", False)),
                _norm_pg(args.get("page", args.get("pg", 1))),
            ),
        )
        return _dict_or_list(result)
    if method == "playerContent":
        result = _call_arity(
            spider.playerContent,
            (
                _as_str(args.get("flag")),
                _as_str(args.get("id")),
                _as_vip_flags(args),
            ),
        )
        return result if isinstance(result, dict) else {}
    if method == "localProxy":
        param = args.get("param", args.get("params", {}))
        result = _call_arity(spider.localProxy, (param,))
        if isinstance(result, (list, tuple)) and len(result) >= 3:
            body = result[2]
            if len(result) >= 5 and result[4] == 1:
                if not isinstance(body, str):
                    raise ValueError("localProxy 返回的 base64 标志置位但 body 不是字符串")
                body_bytes = base64.b64decode(body)
            elif isinstance(body, str):
                body_bytes = body.encode("utf-8")
            elif isinstance(body, bytes):
                body_bytes = body
            else:
                raise ValueError("localProxy 返回的 body 类型不受支持")
            headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
            return {
                "status": int(result[0]),
                "mime": str(result[1] or ""),
                "bodyBase64": base64.b64encode(body_bytes).decode("ascii"),
                "headers": {str(k): str(v) for k, v in headers.items()},
            }
        raise ValueError("localProxy 返回格式不正确")
    if method == "isVideoFormat":
        return bool(spider.isVideoFormat(_as_str(args.get("url"))))
    if method == "manualVideoCheck":
        return bool(spider.manualVideoCheck())
    if method == "action":
        name = _as_str(args.get("name", args.get("action", "")))
        params = args.get("params", args.get("param"))
        if params is None:
            return spider.action(name)
        return _call_arity(spider.action, (name, params))
    raise ValueError("不支持的蜘蛛方法：%s" % method)


def _error_detail(error):
    lines = traceback.format_exc().strip().splitlines()
    tail = lines[-4:] if len(lines) > 4 else lines
    detail = "%s: %s" % (type(error).__name__, error)
    if tail:
        detail = detail + "\n" + "\n".join(tail)
    return detail[:2000]


def handle_json(site_id, method, args_json):
    try:
        with _lock:
            args = json.loads(args_json) if args_json else {}
            if not isinstance(args, dict):
                raise ValueError("请求格式不正确")
            source = args.get("source")
            if not isinstance(source, str) or not source.strip():
                raise ValueError("缺少蜘蛛源码")
            extend = args.get("extend", "")
            if isinstance(extend, str):
                extend_text = extend
            else:
                extend_text = json.dumps(extend, ensure_ascii=False, sort_keys=True)
            spider = _load_spider(str(site_id), source, extend_text)
            data = _dispatch(spider, str(method), args)
            return json.dumps(
                {"ok": True, "data": _jsonable(data)}, ensure_ascii=False
            )
    except Exception as error:
        return json.dumps({"ok": False, "error": _error_detail(error)}, ensure_ascii=False)


def release_json(site_id):
    try:
        with _lock:
            _dispose_locked(str(site_id))
        return json.dumps({"ok": True}, ensure_ascii=False)
    except Exception as error:
        return json.dumps({"ok": False, "error": _error_detail(error)}, ensure_ascii=False)


def status_json():
    try:
        import requests
        has_requests = True
    except Exception:
        has_requests = False
    return json.dumps(
        {
            "available": True,
            "python": sys.version.splitlines()[0] if sys.version else "",
            "requests": has_requests,
            "sslUnverified": _ssl_unverified,
        },
        ensure_ascii=False,
    )
