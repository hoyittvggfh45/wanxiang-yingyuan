package com.wxyy

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

/**
 * 听书悬浮胶囊（灵动岛）原生桥。
 *
 * Dart 侧见 `lib/core/player/audiobook_capsule.dart`。职责：
 * 1. `hasPermission` / `requestPermission`：悬浮窗权限查询与跳系统设置页授权；
 * 2. `show` / `update` / `hide`：WindowManager 悬浮窗胶囊（封面 + 标题 +
 *    播放/暂停 + 关闭），可拖动，点主体回应用；
 * 3. 事件通道回传胶囊按钮点按（`play_pause` / `close` / `tap`）。
 *
 * 原生只负责摆布局与转发点击，不做任何业务判定（显隐决策全在 Dart 侧）。
 * 封面图经 HttpURLConnection 现拉（无图片库依赖），失败显示占位图。
 *
 * 鸿蒙 NEXT + 卓易通容器上悬浮窗能不能用无法在本机验，须用户手机实测。
 */
object AudiobookCapsuleBridge {
    private const val CHANNEL = "wxyy/audiobook_capsule"
    private const val EVENT_CHANNEL = "wxyy/audiobook_capsule_events"

    private var windowManager: WindowManager? = null
    private var appContext: Context? = null
    private var capsuleView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var coverView: ImageView? = null
    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var playPauseButton: ImageButton? = null
    private var eventSink: EventChannel.EventSink? = null
    private var currentArtUrl: String? = null
    private var coverGeneration = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        windowManager =
            context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasPermission())
                "requestPermission" -> result.success(requestPermission())
                "show", "update" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val artUrl = call.argument<String>("artUrl")
                    val playing = call.argument<Boolean>("playing") ?: false
                    result.success(show(title, artist, artUrl, playing))
                }
                "hide" -> {
                    hide()
                    result.success(null)
                }
                "isShowing" -> result.success(capsuleView != null)
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    events: EventChannel.EventSink?,
                ) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    /** Activity 销毁时收起胶囊，避免悬浮窗在应用退出后残留。 */
    fun onDestroy() {
        hide()
    }

    private fun hasPermission(): Boolean {
        val context = appContext ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    private fun requestPermission(): Boolean {
        val context = appContext ?: return false
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun show(
        title: String,
        artist: String,
        artUrl: String?,
        playing: Boolean,
    ): Boolean {
        if (!hasPermission()) return false
        val wm = windowManager ?: return false
        val context = appContext ?: return false
        return try {
            if (capsuleView == null) {
                val view = buildCapsuleView(context)
                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    overlayType(),
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT,
                )
                params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                params.y = statusBarHeight(context) + dp(context, 8)
                wm.addView(view, params)
                capsuleView = view
                layoutParams = params
            }
            updateContent(title, artist, artUrl, playing)
            true
        } catch (_: Exception) {
            hide()
            false
        }
    }

    fun hide() {
        coverGeneration++
        val wm = windowManager
        val view = capsuleView
        capsuleView = null
        layoutParams = null
        coverView = null
        titleView = null
        artistView = null
        playPauseButton = null
        currentArtUrl = null
        if (wm != null && view != null) {
            try {
                wm.removeViewImmediate(view)
            } catch (_: Exception) {
                // 视图已不在窗口上时忽略。
            }
        }
    }

    private fun updateContent(
        title: String,
        artist: String,
        artUrl: String?,
        playing: Boolean,
    ) {
        titleView?.text = title
        artistView?.text = artist
        playPauseButton?.setImageResource(
            if (playing) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            },
        )
        if (artUrl != currentArtUrl) {
            currentArtUrl = artUrl
            loadCover(artUrl)
        }
    }

    private fun loadCover(artUrl: String?) {
        val target = coverView ?: return
        val generation = ++coverGeneration
        if (artUrl.isNullOrEmpty()) {
            target.setImageResource(android.R.drawable.ic_menu_gallery)
            return
        }
        Thread {
            var bitmap: Bitmap? = null
            try {
                val connection =
                    (URL(artUrl).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 8000
                        readTimeout = 8000
                        instanceFollowRedirects = true
                    }
                connection.inputStream.use { input ->
                    bitmap = BitmapFactory.decodeStream(input)
                }
                connection.disconnect()
            } catch (_: Exception) {
                bitmap = null
            }
            val loaded = bitmap
            mainHandler.post {
                if (generation != coverGeneration) return@post
                if (loaded != null) {
                    target.setImageBitmap(loaded)
                } else {
                    target.setImageResource(android.R.drawable.ic_menu_gallery)
                }
            }
        }.start()
    }

    private fun buildCapsuleView(context: Context): View {
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#E6000000"))
                cornerRadius = dp(context, 28).toFloat()
            }
            setPadding(
                dp(context, 6),
                dp(context, 6),
                dp(context, 4),
                dp(context, 6),
            )
            isClickable = true
        }
        val coverSize = dp(context, 44)
        val cover = ImageView(context).apply {
            layoutParams = LinearLayout.LayoutParams(coverSize, coverSize)
            scaleType = ImageView.ScaleType.CENTER_CROP
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, dp(context, 10).toFloat())
                }
            }
            setImageResource(android.R.drawable.ic_menu_gallery)
        }
        val texts = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                marginStart = dp(context, 8)
                marginEnd = dp(context, 4)
            }
        }
        val title = TextView(context).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxWidth = dp(context, 160)
        }
        val artist = TextView(context).apply {
            setTextColor(Color.parseColor("#B3FFFFFF"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxWidth = dp(context, 160)
        }
        texts.addView(title)
        texts.addView(artist)
        val buttonSize = dp(context, 40)
        val playPause = ImageButton(context).apply {
            layoutParams = LinearLayout.LayoutParams(buttonSize, buttonSize)
            setBackgroundColor(Color.TRANSPARENT)
            setImageResource(android.R.drawable.ic_media_play)
            setColorFilter(Color.WHITE)
            contentDescription = "播放/暂停"
            setOnClickListener { eventSink?.success("play_pause") }
        }
        val close = ImageButton(context).apply {
            layoutParams = LinearLayout.LayoutParams(buttonSize, buttonSize)
            setBackgroundColor(Color.TRANSPARENT)
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setColorFilter(Color.WHITE)
            contentDescription = "关闭"
            setOnClickListener {
                // 先原生收起（Dart 侧若已死也不残留），再通知 Dart 暂停。
                hide()
                eventSink?.success("close")
            }
        }
        root.addView(cover)
        root.addView(texts)
        root.addView(playPause)
        root.addView(close)
        coverView = cover
        titleView = title
        artistView = artist
        playPauseButton = playPause
        attachDragAndTap(root, context)
        return root
    }

    /**
     * 拖动与点按：手指移动超阈值则拖动胶囊，否则按点按处理（回应用）。
     * 按钮优先消费自己的点按（子 View 先于父布局收到事件），空白处点按落到这里。
     */
    private fun attachDragAndTap(root: View, context: Context) {
        val slop = ViewConfiguration.get(context).scaledTouchSlop
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var dragging = false
        root.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = layoutParams?.x ?: 0
                    startY = layoutParams?.y ?: 0
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!dragging &&
                        (dx * dx + dy * dy) > slop * slop
                    ) {
                        dragging = true
                    }
                    if (dragging) {
                        val params = layoutParams
                        val view = capsuleView
                        if (params != null && view != null) {
                            params.x = startX + dx.toInt()
                            params.y = startY + dy.toInt()
                            try {
                                windowManager?.updateViewLayout(view, params)
                            } catch (_: Exception) {
                                // 视图已移除时忽略。
                            }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragging) {
                        bringAppToFront()
                        eventSink?.success("tap")
                    }
                    dragging = false
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    true
                }
                else -> false
            }
        }
    }

    private fun bringAppToFront() {
        val context = appContext ?: return
        try {
            val intent =
                context.packageManager.getLaunchIntentForPackage(context.packageName)
            intent?.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
            )
            if (intent != null) context.startActivity(intent)
        } catch (_: Exception) {
            // 拉起失败时不抛错：用户仍可从最近任务手动回应用。
        }
    }

    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }

    private fun statusBarHeight(context: Context): Int {
        val id = context.resources.getIdentifier(
            "status_bar_height",
            "dimen",
            "android",
        )
        return if (id > 0) context.resources.getDimensionPixelSize(id) else 0
    }

    private fun dp(context: Context, value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            context.resources.displayMetrics,
        ).toInt()
    }
}
