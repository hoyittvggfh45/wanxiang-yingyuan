package com.wxyy

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import dalvik.system.DexClassLoader
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

/**
 * 蜘蛛引擎原生侧：py 走 Chaquopy，jar 走 DexClassLoader + 反射。
 *
 * Dart 侧：lib/core/spider/spider_bridges.dart，通道 wxyy/pybridge 与
 * wxyy/jarbridge，方法 status/call/release。约定以 Dart 侧为准：
 * py 调用每次把源码随 args["source"] 传来，jar 调用把 jar 资源路径随
 * args["jarAsset"] 传来、api/ext 在顶层参数里。
 *
 * 调用一律走单线程后台队列，结果回主线程；蜘蛛实例按站点缓存，源码变化
 * 或 ext 变化时重建。错误一律结构化：解释器不可用报 NOT_CONNECTED，
 * 蜘蛛执行失败报 SPIDER_ERROR / JAR_ERROR 并带真实原因，绝不假装成功。
 *
 * Context 不靠 MainActivity 传入（避免改动 MainActivity），取应用级
 * Context：优先 init() 注入，其次 ActivityThread.currentApplication()。
 */
object SpiderBridge {

    private class BridgeError(val code: String, message: String) : Exception(message)

    // ── Context ──────────────────────────────────────────────────────

    @Volatile
    private var contextRef: Context? = null

    /** 供后续 MainActivity 显式注入应用 Context（当前未接线，靠反射兜底）。 */
    fun init(context: Context) {
        contextRef = context.applicationContext
    }

    private fun appContext(): Context {
        contextRef?.let { return it }
        val app = runCatching {
            val threadClass = Class.forName("android.app.ActivityThread")
            threadClass.getMethod("currentApplication").invoke(null) as? Context
        }.getOrNull()
        if (app != null) {
            contextRef = app.applicationContext
            return contextRef!!
        }
        throw BridgeError(
            "NOT_CONNECTED",
            "拿不到应用 Context，蜘蛛引擎无法启动。",
        )
    }

    // ── 线程与通用工具 ───────────────────────────────────────────────

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: BridgeError) {
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                mainHandler.post { result.error("ENGINE_ERROR", message, null) }
            }
        }
    }

    private fun argsMap(call: MethodCall): Map<String, Any?> {
        val raw = call.argument<Map<*, *>>("args") ?: return emptyMap()
        val out = LinkedHashMap<String, Any?>()
        for ((key, value) in raw) {
            if (key != null) out[key.toString()] = value
        }
        return out
    }

    /** MethodChannel 参数 → 可进 JSONObject 的值（字节数组转 base64，空值保留）。 */
    private fun sanitize(value: Any?): Any? {
        return when (value) {
            null -> JSONObject.NULL
            is Map<*, *> -> {
                val out = LinkedHashMap<String, Any?>()
                for ((key, item) in value) {
                    if (key != null) out[key.toString()] = sanitize(item)
                }
                out
            }
            is List<*> -> value.map { sanitize(it) }
            is ByteArray -> Base64.encodeToString(value, Base64.NO_WRAP)
            is String, is Number, is Boolean -> value
            else -> value.toString()
        }
    }

    private fun jsonValue(value: Any?): Any? {
        return when (value) {
            is JSONObject -> {
                val out = LinkedHashMap<String, Any?>()
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    out[key] = jsonValue(value.get(key))
                }
                out
            }
            is JSONArray -> {
                val out = ArrayList<Any?>()
                for (i in 0 until value.length()) out.add(jsonValue(value.get(i)))
                out
            }
            JSONObject.NULL -> null
            else -> value
        }
    }

    // ── Python 引擎（Chaquopy） ──────────────────────────────────────

    private val pythonLock = Any()

    private fun python(): Python {
        synchronized(pythonLock) {
            if (!Python.isStarted()) {
                try {
                    Python.start(AndroidPlatform(appContext()))
                } catch (error: IllegalStateException) {
                    if (!Python.isStarted()) {
                        throw BridgeError(
                            "NOT_CONNECTED",
                            "Python 解释器启动失败：${error.message}",
                        )
                    }
                } catch (error: Throwable) {
                    throw BridgeError(
                        "NOT_CONNECTED",
                        "Python 解释器启动失败：${error.message ?: error.javaClass.simpleName}",
                    )
                }
            }
            return Python.getInstance()
        }
    }

    private fun pyStatus(): Map<String, Any?> {
        return try {
            val text = python().getModule("py_spider_host")
                .callAttr("status_json").toString()
            val obj = JSONObject(text)
            mapOf(
                "connected" to true,
                "python" to obj.optString("python"),
                "requests" to obj.optBoolean("requests"),
            )
        } catch (error: Throwable) {
            mapOf(
                "connected" to false,
                "error" to (error.message ?: error.javaClass.simpleName),
            )
        }
    }

    private fun pyCall(
        siteId: String,
        method: String,
        args: Map<String, Any?>,
    ): Map<String, Any?> {
        val argsJson = JSONObject(sanitize(args) as Map<*, *>).toString()
        val text = try {
            python().getModule("py_spider_host")
                .callAttr("handle_json", siteId, method, argsJson).toString()
        } catch (error: BridgeError) {
            throw error
        } catch (error: Throwable) {
            throw BridgeError(
                "SPIDER_ERROR",
                "Python 引擎调用失败：${error.message ?: error.javaClass.simpleName}",
            )
        }
        val obj = try {
            JSONObject(text)
        } catch (error: Throwable) {
            throw BridgeError("SPIDER_ERROR", "Python 引擎返回了无法解析的结果。")
        }
        if (!obj.optBoolean("ok")) {
            throw BridgeError("SPIDER_ERROR", obj.optString("error", "蜘蛛执行失败"))
        }
        val data = jsonValue(obj.opt("data"))
        return when (data) {
            is Map<*, *> -> {
                val out = LinkedHashMap<String, Any?>()
                for ((key, value) in data) {
                    if (key != null) out[key.toString()] = value
                }
                out
            }
            null -> emptyMap()
            else -> mapOf("value" to data)
        }
    }

    private fun pyRelease(siteId: String) {
        if (!Python.isStarted()) return
        runCatching {
            python().getModule("py_spider_host")
                .callAttr("release_json", siteId)
        }
    }

    fun handlePy(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> runAsync(result) { pyStatus() }
            "call" -> {
                val siteId = call.argument<String>("siteId").orEmpty()
                val method = call.argument<String>("method").orEmpty()
                if (siteId.isEmpty() || method.isEmpty()) {
                    result.error("bad_args", "缺少 siteId 或 method", null)
                    return
                }
                val args = argsMap(call)
                runAsync(result) { pyCall(siteId, method, args) }
            }
            "release" -> {
                val siteId = call.argument<String>("siteId").orEmpty()
                runAsync(result) {
                    pyRelease(siteId)
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    // ── Java jar 引擎（DexClassLoader + 反射） ───────────────────────
    //
    // 签名以 zakatv.jar 的 dex 实测为准（Lcom/github/catvod/crawler/Spider
    // 的方法表）：init(Context, String)、homeContent(boolean)、
    // homeVideoContent()、categoryContent(String, String, boolean, HashMap)、
    // detailContent(List)、searchContent(String, boolean[, String])、
    // playerContent(String, String, List)、proxy/proxyLocal(Map)。
    // jar 的 dex 自带 Spider 基类与 Init，不依赖壳侧 catvod 源码；但 dex
    // 直接调用 okhttp3，须由应用依赖提供（见 app/build.gradle.kts）。

    private val loaders = ConcurrentHashMap<String, DexClassLoader>()
    private val jarSpiders = ConcurrentHashMap<String, Any>()
    private val jarInitDone = ConcurrentHashMap.newKeySet<String>()

    private fun classNameFor(api: String): String {
        val trimmed = api.trim()
        if (trimmed.contains(".")) return trimmed
        val simple = trimmed.removePrefix("csp_")
        return "com.github.catvod.spider.$simple"
    }

    private fun jarKey(jarRef: String): String {
        return jarRef.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80)
    }

    private fun appVersionCode(context: Context): Long {
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(
                    context.packageName,
                    PackageManager.PackageInfoFlags.of(0),
                ).longVersionCode
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(context.packageName, 0)
                    .versionCode.toLong()
            }
        }.getOrDefault(0L)
    }

    /**
     * jar 引用 → 可加载的本地文件。
     *
     * `assets/...` 走 Flutter 资源（`flutter_assets/` 前缀），按应用版本号
     * 分目录缓存，升级后自动取新 jar；`file:` 与绝对路径直接用本地文件。
     */
    private fun resolveJarFile(context: Context, jarRef: String): File {
        val ref = jarRef.trim()
        if (ref.isEmpty()) {
            throw BridgeError("JAR_ERROR", "该 jar 源缺少 jar 资源路径，无法加载。")
        }
        if (ref.startsWith("file:")) {
            val file = File(ref.removePrefix("file://").removePrefix("file:"))
            if (!file.exists()) {
                throw BridgeError("JAR_ERROR", "本地 jar 文件不存在：$ref")
            }
            return file
        }
        if (ref.startsWith("/")) {
            val file = File(ref)
            if (!file.exists()) {
                throw BridgeError("JAR_ERROR", "本地 jar 文件不存在：$ref")
            }
            return file
        }
        val assetPath = if (ref.startsWith("assets/")) ref else "assets/$ref"
        val dir = File(context.filesDir, "jarbridge/${appVersionCode(context)}")
        if (!dir.exists()) dir.mkdirs()
        // 顺手清理旧版本缓存目录，避免多个 8MB 的 jar 残留占空间。
        runCatching {
            context.filesDir.resolve("jarbridge").listFiles()
                ?.filter { it.isDirectory && it.name != dir.name }
                ?.forEach { it.deleteRecursively() }
        }
        val target = File(dir, jarKey(assetPath) + ".jar")
        if (!target.exists()) {
            try {
                context.assets.open("flutter_assets/$assetPath").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (error: Throwable) {
                runCatching { target.delete() }
                throw BridgeError(
                    "JAR_ERROR",
                    "找不到 jar 资源：$assetPath（${error.message ?: error.javaClass.simpleName}）",
                )
            }
        }
        return target
    }

    private fun loaderFor(context: Context, jarRef: String, jarFile: File): DexClassLoader {
        val key = jarKey(jarRef)
        synchronized(loaders) {
            loaders[key]?.let { return it }
            val optimized = File(context.codeCacheDir, "jarbridge_$key")
            if (!optimized.exists()) optimized.mkdirs()
            val loader = try {
                DexClassLoader(
                    jarFile.absolutePath,
                    optimized.absolutePath,
                    null,
                    context.classLoader,
                )
            } catch (error: Throwable) {
                throw BridgeError(
                    "JAR_ERROR",
                    "jar 加载失败：${error.message ?: error.javaClass.simpleName}",
                )
            }
            loaders[key] = loader
            return loader
        }
    }

    /** 反射调 jar 内 Init.init(Context)，失败不拦路（部分蜘蛛用不到它）。 */
    private fun ensureJarInit(loader: DexClassLoader, context: Context, key: String) {
        if (!jarInitDone.add(key)) return
        runCatching {
            val initClass = loader.loadClass("com.github.catvod.spider.Init")
            initClass.getMethod("init", Context::class.java)
                .invoke(null, context.applicationContext)
        }
    }

    private fun jarSpiderFor(
        context: Context,
        siteId: String,
        jarRef: String,
        className: String,
        ext: String,
    ): Any {
        val key = "$siteId|$className|$ext"
        jarSpiders[key]?.let { return it }
        synchronized(jarSpiders) {
            jarSpiders[key]?.let { return it }
            val jarFile = resolveJarFile(context, jarRef)
            val loader = loaderFor(context, jarRef, jarFile)
            ensureJarInit(loader, context, jarKey(jarRef))
            val type = try {
                loader.loadClass(className)
            } catch (error: ClassNotFoundException) {
                throw BridgeError(
                    "JAR_ERROR",
                    "jar 中未找到站点类 $className，api 与 jar 不匹配或 jar 不完整。",
                )
            } catch (error: LinkageError) {
                throw BridgeError(
                    "JAR_ERROR",
                    "jar 类 $className 加载失败（可能缺运行时依赖）：${error.message}",
                )
            }
            val instance = try {
                val ctor = type.getDeclaredConstructor()
                ctor.isAccessible = true
                ctor.newInstance()
            } catch (error: Throwable) {
                throw BridgeError(
                    "JAR_ERROR",
                    "jar 站点类 $className 无法实例化：${error.message}",
                )
            }
            try {
                type.getMethod("init", Context::class.java, String::class.java)
                    .invoke(instance, context.applicationContext, ext)
            } catch (error: NoSuchMethodException) {
                runCatching {
                    type.getMethod("init", Context::class.java)
                        .invoke(instance, context.applicationContext)
                }
            } catch (error: InvocationTargetException) {
                val cause = error.targetException
                throw BridgeError(
                    "JAR_ERROR",
                    "jar 站点 $className 初始化失败：${cause?.message ?: cause?.javaClass?.simpleName}",
                )
            }
            runCatching {
                val initClass = loader.loadClass("com.github.catvod.spider.Init")
                val spiderBase = loader.loadClass("com.github.catvod.crawler.Spider")
                initClass.getMethod("registerSpider", String::class.java, spiderBase)
                    .invoke(null, className, instance)
            }
            jarSpiders[key] = instance
            return instance
        }
    }

    private fun jarRelease(siteId: String) {
        val keys = jarSpiders.keys.filter { it.startsWith("$siteId|") }
        for (key in keys) {
            val instance = jarSpiders.remove(key) ?: continue
            runCatching { instance.javaClass.getMethod("destroy").invoke(instance) }
            runCatching {
                val loader = instance.javaClass.classLoader ?: return@runCatching
                val initClass = loader.loadClass("com.github.catvod.spider.Init")
                initClass.getMethod("unregisterSpider", String::class.java)
                    .invoke(null, instance.javaClass.name)
            }
        }
    }

    private fun strArg(args: Map<String, Any?>, default: String, vararg keys: String): String {
        for (key in keys) {
            val value = args[key]
            if (value != null) return value.toString()
        }
        return default
    }

    private fun filterArg(args: Map<String, Any?>): Boolean {
        return (args["filter"] as? Boolean) ?: true
    }

    private fun extendArg(args: Map<String, Any?>): HashMap<String, String> {
        val out = HashMap<String, String>()
        val raw = (args["extend"] as? Map<*, *>) ?: (args["ext"] as? Map<*, *>)
        raw?.forEach { (key, value) ->
            if (key != null && value != null) out[key.toString()] = value.toString()
        }
        return out
    }

    private fun stringListArg(args: Map<String, Any?>, vararg keys: String): List<String> {
        for (key in keys) {
            val value = args[key]
            if (value is List<*>) return value.map { it.toString() }
            if (value is String && value.isNotEmpty()) return listOf(value)
        }
        return emptyList()
    }

    private fun invokeSpider(
        spider: Any,
        className: String,
        method: String,
        block: () -> Any?,
    ): Any? {
        return try {
            block()
        } catch (error: InvocationTargetException) {
            val cause = error.targetException
            throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className.$method 执行失败：" +
                    "${cause?.message ?: cause?.javaClass?.simpleName ?: "未知错误"}",
            )
        } catch (error: NoSuchMethodException) {
            throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 未实现方法 $method（与蜘蛛契约不符）。",
            )
        }
    }

    /** jar 方法返回的 JSON 字符串 → Map；空串回空 Map，非 JSON 按方法分流。 */
    private fun parseJarJson(text: String, method: String): Map<String, Any?> {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return emptyMap()
        try {
            val parsed = jsonValue(JSONObject(trimmed))
            if (parsed is Map<*, *>) {
                val out = LinkedHashMap<String, Any?>()
                for ((key, value) in parsed) {
                    if (key != null) out[key.toString()] = value
                }
                return out
            }
        } catch (_: Throwable) {
        }
        try {
            val parsed = jsonValue(JSONArray(trimmed))
            if (parsed is List<*>) return mapOf("value" to parsed)
        } catch (_: Throwable) {
        }
        if (method == "getName" || method == "action" || method == "getDependence") {
            return mapOf("value" to text)
        }
        throw BridgeError(
            "JAR_ERROR",
            "jar 蜘蛛返回了非 JSON 结果：${trimmed.take(200)}",
        )
    }

    private fun jarLocalProxy(
        spider: Any,
        className: String,
        args: Map<String, Any?>,
    ): Map<String, Any?> {
        val raw = (args["param"] as? Map<*, *>)
            ?: (args["params"] as? Map<*, *>)
            ?: args
        val param = HashMap<String, String>()
        raw.forEach { (key, value) ->
            if (key != null && value != null) param[key.toString()] = value.toString()
        }
        val type = spider.javaClass
        val returned = try {
            val method = try {
                type.getMethod("proxyLocal", Map::class.java)
            } catch (_: NoSuchMethodException) {
                type.getMethod("proxy", Map::class.java)
            }
            if (java.lang.reflect.Modifier.isStatic(method.modifiers)) {
                method.invoke(null, param)
            } else {
                method.invoke(spider, param)
            }
        } catch (error: NoSuchMethodException) {
            throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 未实现 proxyLocal/proxy，无法处理本地代理请求。",
            )
        } catch (error: InvocationTargetException) {
            val cause = error.targetException
            throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 本地代理执行失败：" +
                    "${cause?.message ?: cause?.javaClass?.simpleName}",
            )
        }
        val array = returned as? Array<*>
            ?: throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 代理返回格式错误：需要 [状态码、类型、字节流]。",
            )
        if (array.size < 3) {
            throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 代理返回格式错误：需要 [状态码、类型、字节流]。",
            )
        }
        val status = (array[0] as? Number)?.toInt() ?: 200
        val mime = array[1] as? String ?: "application/octet-stream"
        val body = when (val rawBody = array[2]) {
            is ByteArray -> rawBody
            is String -> rawBody.toByteArray(Charsets.UTF_8)
            is java.io.InputStream -> rawBody.use { it.readBytes() }
            else -> throw BridgeError(
                "JAR_ERROR",
                "jar 站点 $className 代理返回的字节流类型不受支持。",
            )
        }
        val out = LinkedHashMap<String, Any?>()
        out["status"] = status
        out["mime"] = mime
        out["bodyBase64"] = Base64.encodeToString(body, Base64.NO_WRAP)
        if (array.size >= 4 && array[3] is Map<*, *>) {
            val headers = LinkedHashMap<String, String>()
            (array[3] as Map<*, *>).forEach { (key, value) ->
                if (key != null && value != null) {
                    headers[key.toString()] = value.toString()
                }
            }
            out["headers"] = headers
        }
        return out
    }

    private fun jarCall(
        context: Context,
        siteId: String,
        api: String,
        ext: String,
        method: String,
        args: Map<String, Any?>,
    ): Map<String, Any?> {
        val className = classNameFor(api)
        val jarRef = (args["jarAsset"] as? String).orEmpty()
        val spider = jarSpiderFor(context, siteId, jarRef, className, ext)
        val type = spider.javaClass
        fun text(value: Any?): String = value as? String ?: ""
        return when (method) {
            "homeContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("homeContent", java.lang.Boolean.TYPE)
                            .invoke(spider, filterArg(args))
                    },
                ),
                method,
            )
            "homeVideoContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("homeVideoContent").invoke(spider)
                    },
                ),
                method,
            )
            "categoryContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod(
                            "categoryContent",
                            String::class.java,
                            String::class.java,
                            java.lang.Boolean.TYPE,
                            HashMap::class.java,
                        ).invoke(
                            spider,
                            strArg(args, "", "tid"),
                            strArg(args, "1", "pg", "page"),
                            filterArg(args),
                            extendArg(args),
                        )
                    },
                ),
                method,
            )
            "detailContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("detailContent", List::class.java)
                            .invoke(spider, stringListArg(args, "ids", "id"))
                    },
                ),
                method,
            )
            "searchContent" -> {
                val key = strArg(args, "", "key", "keyword")
                val quick = (args["quick"] as? Boolean) ?: false
                val pg = strArg(args, "1", "pg", "page")
                val paged = runCatching {
                    type.getMethod(
                        "searchContent",
                        String::class.java,
                        java.lang.Boolean.TYPE,
                        String::class.java,
                    )
                }.getOrNull()
                val raw = if (paged != null) {
                    text(
                        invokeSpider(spider, className, method) {
                            paged.invoke(spider, key, quick, pg)
                        },
                    )
                } else {
                    text(
                        invokeSpider(spider, className, method) {
                            type.getMethod(
                                "searchContent",
                                String::class.java,
                                java.lang.Boolean.TYPE,
                            ).invoke(spider, key, quick)
                        },
                    )
                }
                parseJarJson(raw, method)
            }
            "playerContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod(
                            "playerContent",
                            String::class.java,
                            String::class.java,
                            List::class.java,
                        ).invoke(
                            spider,
                            strArg(args, "", "flag"),
                            strArg(args, "", "id"),
                            stringListArg(args, "vipFlags", "vipFlag"),
                        )
                    },
                ),
                method,
            )
            "getName" -> mapOf(
                "value" to text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("getName").invoke(spider)
                    },
                ),
            )
            "getDependence" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("getDependence").invoke(spider)
                    },
                ),
                method,
            )
            "action" -> mapOf(
                "value" to text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("action", String::class.java)
                            .invoke(spider, strArg(args, "", "name", "action"))
                    },
                ),
            )
            "liveContent" -> parseJarJson(
                text(
                    invokeSpider(spider, className, method) {
                        type.getMethod("liveContent", String::class.java)
                            .invoke(spider, strArg(args, "", "url", "id"))
                    },
                ),
                method,
            )
            "isVideoFormat" -> mapOf(
                "value" to (
                    invokeSpider(spider, className, method) {
                        type.getMethod("isVideoFormat", String::class.java)
                            .invoke(spider, strArg(args, "", "url"))
                    } as? Boolean ?: false
                    ),
            )
            "manualVideoCheck" -> mapOf(
                "value" to (
                    invokeSpider(spider, className, method) {
                        type.getMethod("manualVideoCheck").invoke(spider)
                    } as? Boolean ?: false
                    ),
            )
            "localProxy" -> jarLocalProxy(spider, className, args)
            else -> throw BridgeError("JAR_ERROR", "jar 桥不支持的方法：$method")
        }
    }

    fun handleJar(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> runAsync(result) {
                // DexClassLoader 是系统 API，引擎已接线即为接通；jar 缺失等
                // 问题在每次调用时如实报错，不在 status 里假装。
                mapOf("connected" to true)
            }
            "call" -> {
                val siteId = call.argument<String>("siteId").orEmpty()
                val api = call.argument<String>("api").orEmpty()
                val ext = call.argument<String>("ext").orEmpty()
                val method = call.argument<String>("method").orEmpty()
                if (siteId.isEmpty() || api.isEmpty() || method.isEmpty()) {
                    result.error("bad_args", "缺少 siteId、api 或 method", null)
                    return
                }
                val args = argsMap(call)
                runAsync(result) {
                    jarCall(appContext(), siteId, api, ext, method, args)
                }
            }
            "release" -> {
                val siteId = call.argument<String>("siteId").orEmpty()
                runAsync(result) {
                    jarRelease(siteId)
                    null
                }
            }
            else -> result.notImplemented()
        }
    }
}
