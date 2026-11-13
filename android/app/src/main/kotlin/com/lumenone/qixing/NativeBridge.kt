package com.lumenone.qixing

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * `gtd/native`（Dart → 原生）与 `gtd/native/events`（原生 → Dart）两条 MethodChannel 的实现，
 * 外加闹钟广播 Intent 的构造辅助方法（站点表的挂钟/取消归 `AlarmStationStore`）。
 *
 * 生命周期约定：
 * - 每个 [MainActivity] 创建时 new 一个实例；channel 注册在 configureFlutterEngine 里；
 * - 接收器（闹钟/通知按钮）醒来时进程可能没有 Activity，此时 [activeInstance] 为 null，
 *   事件进 SharedPreferences 队列，等 Dart 调 `drainEvents`/`notifyReady` 再取；
 * - [NativeEventQueue] 保证队内事件与直接投递互斥，不会重复投递。
 */
class NativeBridge(
    private val activity: MainActivity,
    private val engine: FlutterEngine,
) {

    companion object {
        const val CHANNEL_METHODS = "gtd/native"
        const val CHANNEL_EVENTS = "gtd/native/events"

        private const val TAG = "gtd"

        /** 灵感文件选择器（`pickMarkdownFile`）。 */
        private const val PICK_FILE_REQUEST_CODE = 1

        /** 响铃时长缺省值（秒）：只在 Dart 没带 `ringSeconds` 时用到。 */
        private const val DEFAULT_RING_SECONDS = 60

        /** 当前活着的 bridge（供接收器直接投递事件）。 */
        @Volatile
        var activeInstance: NativeBridge? = null
            private set
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 冷启动时 Intent 里带过来的 focusTaskId，等 Dart ready 后再投递，避免丢事件。 */
    @Volatile
    private var pendingFocusTaskId: String? = null

    @Volatile
    private var pendingOpenPanel = false

    /** 悬浮面板 `openApp{target="settings"}` 的冷启动补投标记。 */
    @Volatile
    private var pendingOpenSettings = false

    /** 悬浮面板 `openApp{routineId=…}` 的冷启动补投值。 */
    @Volatile
    private var pendingFocusRoutineId: String? = null

    /** Dart 侧说事件通道已就绪；ready 之前一律只入队。可能被接收器线程读，故 @Volatile。 */
    @Volatile
    private var dartReady = false

    /** false = 没有 Dart 监听者（例如 engine 只跑 Dart 后台 isolate），事件必须留在队列。 */
    @Volatile
    private var eventChannelReady = true

    /** 等着回话的 `pickMarkdownFile` 调用：选择器是异步的，结果从 onActivityResult 回来。 */
    private var pendingPick: MethodChannel.Result? = null

    // ---------------------------------------------------------------- 方法通道

    fun attach() {
        // engine 重建时旧 bridge 可能还攒着没投出去的冷启动事件：先落盘，保证不丢。
        activeInstance?.takeIf { it !== this }?.flushPendingToQueue()
        activeInstance = this
        val events = MethodChannel(engine.dartExecutor, CHANNEL_EVENTS)
        events.setMethodCallHandler { call, result ->
            if (call.method == "notifyReady" || call.method == "ready") {
                dartReady = true
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        eventChannel = events

        val channel = MethodChannel(engine.dartExecutor, CHANNEL_METHODS)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        methodChannel = channel

        // 新一次 attach 意味着 Dart 侧通道尚未确认；等 notifyReady 再直投。
        dartReady = false
        eventChannelReady = true
        NativeEventQueue.setDirectDeliverer { event -> deliverNow(event) }
        Log.i(TAG, "NativeBridge attached")
    }

    fun detach() {
        flushPendingToQueue()
        // 选择器还开着时 Activity 就被销毁（低内存重建）：先回话，别让 Dart 那头的
        // future 永远挂着——回 null 等于"没选"，UI 保持原路径。
        pendingPick?.success(null)
        pendingPick = null
        val wasActive = activeInstance === this
        if (wasActive) activeInstance = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setMethodCallHandler(null)
        eventChannel = null
        dartReady = false
        // 只有"当前活跃的 bridge"才有资格拆掉全局直投通道，
        // 否则旧 Activity 的销毁会把新 engine 的通道一起抹掉。
        if (wasActive) NativeEventQueue.clearDirectDeliverer()
    }

    /** 把尚未投出的冷启动事件压进持久队列（engine 重建 / Activity 销毁时用）。 */
    private fun flushPendingToQueue() {
        val taskId = pendingFocusTaskId
        if (taskId != null) {
            pendingFocusTaskId = null
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
        }
        val routineId = pendingFocusRoutineId
        if (routineId != null) {
            pendingFocusRoutineId = null
            NativeEventQueue.enqueueOnly(
                activity,
                mapOf("type" to "focusRoutine", "routineId" to routineId),
            )
        }
        if (pendingOpenPanel) {
            pendingOpenPanel = false
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "overlayHandleOpened"))
        }
        if (pendingOpenSettings) {
            pendingOpenSettings = false
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "openSettings"))
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "scheduleStations" -> result.success(scheduleStations(call))
                "cancelAlarm" -> result.success(cancelAlarm())
                "showNotification" -> result.success(showNotification(call))
                "cancelNotification" -> result.success(cancelNotification(call))
                "startRinging" -> result.success(startRinging(call))
                "stopRinging" -> result.success(stopRinging(call))
                "drainEvents" -> result.success(NativeEventQueue.drain(activity))
                "canUseFullScreenIntent" -> result.success(Notifier.canUseFullScreenIntent(activity))
                "requestFullScreenIntentPermission" -> result.success(requestFullScreenIntentPermission())
                "hasOverlayPermission" -> result.success(hasOverlayPermission())
                "requestOverlayPermission" -> result.success(requestOverlayPermission())
                "setOverlayHandle" -> result.success(setOverlayHandle(call))
                "setHandleLocked" -> result.success(setHandleLocked(call))
                "setHandleHotWidth" -> result.success(setHandleHotWidth(call))
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "openBackgroundSettings" -> result.success(openBackgroundSettings())
                "appVersion" -> result.success(appVersion())
                "pickMarkdownFile" -> {
                    // 异步：结果从 onActivityResult 回来，这里先不回话。
                    pickMarkdownFile(result)
                    return
                }
                "notifyReady" -> {
                    dartReady = true
                    result.success(true)
                    flushPendingIntents()
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // 契约：任何失败都只回 false，不让异常穿过 channel。
            Log.w(TAG, "method ${call.method} failed: ${t.message}", t)
            result.success(false)
        }
    }

    // ------------------------------------------------------------------- 闹钟

    /**
     * 整张站点表一次下发，交给 [AlarmStationStore] 存盘并逐站挂上。
     *
     * 响铃时长也随表落盘：到点那一刻应用可能已经不在，原生没有别的地方问这个值
     * （settings.json 归 Dart 读）。
     */
    private fun scheduleStations(call: MethodCall): Boolean {
        val raw = call.argument<List<Any?>>("stations") ?: return false
        val seconds = call.argument<Number>("ringSeconds")?.toInt() ?: DEFAULT_RING_SECONDS
        val stations = JSONArray()
        for (item in raw) {
            val map = item as? Map<*, *> ?: continue
            val at = (map["atMillis"] as? Number)?.toLong() ?: continue
            val taskId = map["taskId"] as? String ?: continue
            val station = JSONObject()
            station.put("at", at)
            station.put(ReminderExtras.TASK_ID, taskId)
            station.put(ReminderExtras.TITLE, map["title"] as? String ?: "该做这件事了")
            (map["body"] as? String)?.let { station.put(ReminderExtras.BODY, it) }
            station.put(
                ReminderExtras.CHANNEL,
                (map["channel"] as? String ?: "ring").lowercase(),
            )
            station.put(ReminderExtras.FULL_SCREEN, map["fullScreen"] == true)
            val ids = ArrayList<String>()
            val labels = ArrayList<String>()
            val actions = map["actions"] as? List<*>
            if (actions != null) {
                for (action in actions) {
                    val a = action as? Map<*, *> ?: continue
                    val id = a["id"] as? String ?: continue
                    ids += id
                    labels += a["label"] as? String ?: id
                }
            }
            station.put(ReminderExtras.ACTION_IDS, JSONArray(ids))
            station.put(ReminderExtras.ACTION_LABELS, JSONArray(labels))
            station.put("fired", false)
            stations.put(station)
        }
        return AlarmStationStore.replaceAndSchedule(activity, stations, seconds)
    }

    /** 取消表里的所有闹钟（不清表：开机恢复还要照它挂回来）。 */
    private fun cancelAlarm(): Boolean = try {
        AlarmStationStore.cancelAll(activity)
        true
    } catch (t: Throwable) {
        Log.w(TAG, "cancelAlarm failed: ${t.message}")
        false
    }

    // ------------------------------------------------------------------- 通知

    private fun showNotification(call: MethodCall): Boolean {
        val reminder = readReminder(call, requireAt = false) ?: return false
        return Notifier.post(activity, reminder)
    }

    private fun cancelNotification(call: MethodCall): Boolean {
        val taskId = call.argument<String>("taskId") ?: return false
        return Notifier.cancel(activity, taskId)
    }

    // ------------------------------------------------------------------- 响铃

    /**
     * 起铃 / 续期（`AlarmRingPort.start`，ui-interaction.md §7.2）。
     *
     * 平时到点起铃走 [ReminderReceiver]（应用被杀也照响）；这一条是应用自己发起的补投，
     * 两条都落到 [AlarmRingService.start]：同一件重复调用只是续期。
     *
     * @return true = 前台服务已拉起；false = 系统拒绝（后台启动受限等），调用方降级。
     */
    private fun startRinging(call: MethodCall): Boolean {
        val reminder = readReminder(call, requireAt = false) ?: return false
        val seconds = call.argument<Number>("seconds")?.toInt() ?: DEFAULT_RING_SECONDS
        return AlarmRingService.start(activity, reminder, seconds)
    }

    /** 提前停（`AlarmRingPort.stop`）：响的不是这一件就什么都不做。 */
    private fun stopRinging(call: MethodCall): Boolean {
        val taskId = call.argument<String>("taskId") ?: return false
        val ringing = AlarmRingService.ringingTaskId
        if (ringing != null && ringing != taskId) return true
        AlarmRingService.stop(activity)
        return true
    }

    // ------------------------------------------------------------- 权限与查询

    private fun requestFullScreenIntentPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "open full-screen-intent settings failed: ${t.message}")
        }
        // 系统设置是异步的，这里返回"此刻"的状态，Dart 侧应在 resume 后再查询一次。
        return Notifier.canUseFullScreenIntent(activity)
    }

    private fun hasOverlayPermission(): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            true
        } else {
            try {
                Settings.canDrawOverlays(activity)
            } catch (_: Throwable) {
                false
            }
        }

    private fun requestOverlayPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        try {
            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                data = Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "open overlay settings failed: ${t.message}")
            // 部分 ROM 不支持带 package 的 ACTION_MANAGE_OVERLAY_PERMISSION，退化为总列表。
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Throwable) {
                // 彻底打不开就只回报状态
            }
        }
        return hasOverlayPermission()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        try {
            val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
            power?.isIgnoringBatteryOptimizations(activity.packageName) ?: false
        } catch (_: Throwable) {
            false
        }

    /**
     * 国产 ROM 的自启动 / 允许后台运行 / 关闭耗电保护没有标准 API，也查不准状态：
     * 尽量打开厂商的安全中心，打不开就退到本应用的系统详情页，让人自己找那几项。
     * OPPO 的省电策略不看 `isIgnoringBatteryOptimizations`，这个 flag 常常显示已授予
     * 却照样把进程冻住，所以只能引导手动放行。
     */
    private fun openBackgroundSettings(): Boolean {
        for (pkg in listOf(
            "com.coloros.oppoguardelf",
            "com.oppo.safe",
            "com.coloros.safecenter",
            "com.miui.securitycenter",
        )) {
            val launch = try {
                activity.packageManager.getLaunchIntentForPackage(pkg)
            } catch (_: Throwable) {
                null
            } ?: continue
            try {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(launch)
                return true
            } catch (_: Throwable) {
                // 包在但入口被 ROM 改过：接着试下一个。
            }
        }
        return try {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (t: Throwable) {
            Log.w(TAG, "open app details failed: ${t.message}")
            false
        }
    }

    // ------------------------------------------------------------------- 关于

    /**
     * 安装包的版本：`versionName` + `versionCode`（设置页那张关于卡，ui-interaction §9 #14）。
     *
     * 不引 `package_info_plus`——那个插件的安卓 Gradle 脚本自己 apply 了 Kotlin Gradle
     * Plugin，而 AGP 9 起 Kotlin 内置、Flutter 往后会禁掉这条路。这里只回两截事实，
     * `1.2.0 (4)` 这种拼法留在 Dart 侧。
     */
    private fun appVersion(): Map<String, String> {
        val pm = activity.packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(activity.packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf(
            "version" to (info.versionName ?: ""),
            "build" to code.toString(),
        )
    }

    private fun setOverlayHandle(call: MethodCall): Boolean {
        val enabled = call.argument<Boolean>("enabled") ?: false
        return OverlayHandleService.setEnabled(activity, enabled)
    }

    /**
     * 把手位置上锁（settings.json 的 `handle_locked` 的执行侧）。
     *
     * 只锁"竖向拖动改变 y"，长按换边与横拖拉开都照旧。服务没在跑也没关系——
     * 值已落原生 prefs，下次服务 onCreate 会读到。
     */
    private fun setHandleLocked(call: MethodCall): Boolean {
        val locked = call.argument<Boolean>("locked") ?: false
        OverlayHandleService.setLocked(activity, locked)
        return true
    }

    /**
     * 把手热区宽度（settings.json 的 `handle_hot_width` 的执行侧）。
     *
     * 改的是把手窗口宽度与它声明的手势排除区；服务没在跑也没关系——
     * 值已落原生 prefs，下次服务 onCreate 会读到。
     */
    private fun setHandleHotWidth(call: MethodCall): Boolean {
        val dp = call.argument<Number>("widthDp")?.toInt() ?: return false
        OverlayHandleService.setHotZoneWidth(activity, dp)
        return true
    }

    // -------------------------------------------------------------- 事件投递

    /**
     * 直接投递（当前 Activity + Dart ready）。
     *
     * @return true = 已交给 Dart，调用方无须入队。
     */
    private fun deliverNow(event: Map<String, Any?>): Boolean {
        val channel = eventChannel
        if (!dartReady || !eventChannelReady || channel == null) return false
        // 接收器可能在任意线程上醒来；MethodChannel 只能在平台主线程上调。
        if (Looper.myLooper() !== Looper.getMainLooper()) {
            mainHandler.post { deliverNow(event) }
            return true
        }
        return try {
            channel.invokeMethod("event", event)
            true
        } catch (t: Throwable) {
            // MissingPluginException / channel 已失效：本次返回 false 让
            // NativeEventQueue.publish 把事件落进持久队列（恰好一次）。
            eventChannelReady = false
            Log.w(TAG, "direct event delivery failed, queueing: ${t.message}")
            false
        }
    }

    /** 冷启动 intent 的补投（在 Dart notifyReady 之后调用）。 */
    private fun flushPendingIntents() {
        val taskId = pendingFocusTaskId
        if (taskId != null) {
            pendingFocusTaskId = null
            NativeEventQueue.publish(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
        }
        val routineId = pendingFocusRoutineId
        if (routineId != null) {
            pendingFocusRoutineId = null
            NativeEventQueue.publish(
                activity,
                mapOf("type" to "focusRoutine", "routineId" to routineId),
            )
        }
        if (pendingOpenPanel) {
            pendingOpenPanel = false
            NativeEventQueue.publish(activity, mapOf("type" to "overlayHandleOpened"))
        }
        if (pendingOpenSettings) {
            pendingOpenSettings = false
            NativeEventQueue.publish(activity, mapOf("type" to "openSettings"))
        }
    }

    /**
     * 由 [MainActivity] 在 onCreate/onNewIntent 调用。
     *
     * Dart 还没 ready 时先把参数挂进 pending 字段，避免冷启动丢事件。
     */
    fun onActivityIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.getBooleanExtra(MainActivity.EXTRA_OPEN_PANEL, false)) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "overlayHandleOpened"))
            } else {
                pendingOpenPanel = true
            }
        }
        val taskId = intent.getStringExtra(MainActivity.EXTRA_FOCUS_TASK_ID)
        if (!taskId.isNullOrEmpty()) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
            } else {
                pendingFocusTaskId = taskId
            }
        }
        // 悬浮面板 openApp{target="settings"}：落到设置页。
        if (intent.getBooleanExtra(MainActivity.EXTRA_OPEN_SETTINGS, false)) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "openSettings"))
            } else {
                pendingOpenSettings = true
            }
        }
        // 悬浮面板 openApp{routineId=…}：落到该日程。
        val routineId = intent.getStringExtra(MainActivity.EXTRA_FOCUS_ROUTINE_ID)
        if (!routineId.isNullOrEmpty()) {
            if (dartReady) {
                NativeEventQueue.publish(
                    activity,
                    mapOf("type" to "focusRoutine", "routineId" to routineId),
                )
            } else {
                pendingFocusRoutineId = routineId
            }
        }
        // 同一个 Intent 在 Activity 重建/engine 重建时可能被再看一遍：读过就抹掉，
        // 保证一次点击只产生一个事件（pending 也已记下，不会因此丢失）。
        intent.removeExtra(MainActivity.EXTRA_FOCUS_TASK_ID)
        intent.removeExtra(MainActivity.EXTRA_OPEN_PANEL)
        intent.removeExtra(MainActivity.EXTRA_OPEN_SETTINGS)
        intent.removeExtra(MainActivity.EXTRA_FOCUS_ROUTINE_ID)
    }

    // ------------------------------------------------------------------ 解析

    private fun readReminder(call: MethodCall, requireAt: Boolean): Reminder? {
        val taskId = call.argument<String>("taskId") ?: return null
        val title = call.argument<String>("title") ?: return null
        if (requireAt && call.argument<Number>("atMillis") == null) return null
        val actions = mutableListOf<ReminderAction>()
        val rawActions = call.argument<List<Any?>>("actions")
        rawActions?.forEach { item ->
            val map = item as? Map<*, *> ?: return@forEach
            val id = map["id"] as? String ?: return@forEach
            val label = map["label"] as? String ?: id
            actions += ReminderAction(id, label)
        }
        return Reminder(
            taskId = taskId,
            title = title,
            body = call.argument<String>("body"),
            channel = ReminderChannel.fromName(call.argument<String>("channel")),
            fullScreen = call.argument<Boolean>("fullScreen") ?: false,
            actions = actions,
        )
    }

    // -------------------------------------------------------- 文件选择（灵感页）

    /**
     * 挑一个 Markdown，回**真实文件路径**（灵感页入口，见 docs/panels/notes.md §6.2）。
     *
     * 不走 file_picker：它挑文件一律把原件复制进 App 缓存再回副本路径，写回就写进副本，
     * Obsidian 里那份永远不动（挑目录走的是另一条分支，所以任务目录一直好好的）。
     * 这里自己发 SAF，再把 documentId 换回共享存储上的真实路径——应用有"所有文件访问"，
     * 换出来的路径直接可读写。
     *
     * 不按 MIME 过滤：`.md` 在不同 ROM 上被标成 `text/markdown` /
     * `application/octet-stream` 都有，过滤条件一旦对不上，文件在选择器里就是灰的、
     * 根本点不着。类型交给 Dart 侧验。
     */
    private fun pickMarkdownFile(result: MethodChannel.Result) {
        // 同时只挂一个：连点两下时前一次按取消处理，避免回调挂在旧 Result 上。
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            activity.startActivityForResult(intent, PICK_FILE_REQUEST_CODE)
        } catch (t: Throwable) {
            Log.w(TAG, "pickMarkdownFile: 没有可用的文件选择器", t)
            pendingPick = null
            result.success(null)
        }
    }

    /**
     * 选择器结果（[MainActivity.onActivityResult] 转发）。
     *
     * @return true = 这次结果归这里（已回话），调用方不必再交给别处。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FILE_REQUEST_CODE) return false
        val waiting = pendingPick ?: return true
        pendingPick = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        waiting.success(uri?.let { resolveDocumentPath(it) })
        return true
    }

    /**
     * document URI → 共享存储上的真实路径；换不出来（云盘、"最近"里挑到的特殊 provider）
     * 回 null，UI 退回手输。
     */
    private fun resolveDocumentPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path?.takeIf { File(it).canRead() }
        val candidates = ArrayList<String>(2)
        try {
            when (uri.authority) {
                // 共享存储：documentId = "primary:Documents/vault/灵感.md"；
                // 非主卷是 "<卷标>:<相对路径>"（如 "1B0F-3A2E:notes/灵感.md"）。
                "com.android.externalstorage.documents" -> {
                    val split = DocumentsContract.getDocumentId(uri).split(':', limit = 2)
                    if (split.size == 2) {
                        val root =
                            if (split[0].equals("primary", ignoreCase = true)) {
                                Environment.getExternalStorageDirectory().absolutePath
                            } else {
                                "/storage/${split[0]}"
                            }
                        candidates += if (split[1].isEmpty()) root else "$root/${split[1]}"
                    }
                }
                // 下载目录：documentId 形如 "raw:/storage/emulated/0/Download/灵感.md"。
                "com.android.providers.downloads.documents" -> {
                    val docId = DocumentsContract.getDocumentId(uri)
                    if (docId.startsWith("raw:")) candidates += docId.removePrefix("raw:")
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "resolveDocumentPath: documentId 解析失败", t)
        }
        candidates += queryDataColumn(uri)
        return candidates.firstOrNull { it.isNotBlank() && File(it).canRead() }
    }

    /** 兜底：直接问 provider 要 `_data` 列（有"所有文件访问"才读得到）。 */
    private fun queryDataColumn(uri: Uri): List<String> = try {
        val out = ArrayList<String>(1)
        activity.contentResolver
            .query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.takeIf { it.isNotBlank() }?.let { out += it }
                }
            }
        out
    } catch (t: Throwable) {
        emptyList()
    }
}

// ---------------------------------------------------------------- 闹钟 Intent

/**
 * 构造闹钟广播 Intent。
 *
 * 站点表里每一站的 PendingIntent 身份由**表下标**（requestCode）区分，extras 不参与
 * 匹配，所以这里固定 action 串，取消与开机恢复都能按同一套规则命中。站点自己的
 * 时刻与主键由 `AlarmStationStore` 在挂钟那一刻补进 extras。
 *
 * [ringSeconds] 一起带上：到点那一刻应用可能已经被杀，接收器没有别的地方问响铃时长。
 */
internal fun alarmIntent(
    context: Context,
    reminder: Reminder,
    ringSeconds: Int,
): Intent =
    Intent(context, ReminderReceiver::class.java).apply {
        setAction(ReminderReceiver.ACTION_REMINDER_ALARM)
        putReminderExtras(reminder)
        putExtra(ReminderExtras.RING_SECONDS, ringSeconds)
    }

/** 从闹钟 Intent extras 还原 [Reminder]；缺字段时给出安全默认值。 */
internal fun reminderFromIntent(intent: Intent): Reminder {
    val taskId = intent.getStringExtra(ReminderExtras.TASK_ID).orEmpty()
    val ids = intent.getStringArrayListExtra(ReminderExtras.ACTION_IDS).orEmpty()
    val labels = intent.getStringArrayListExtra(ReminderExtras.ACTION_LABELS).orEmpty()
    val actions = ids.mapIndexed { index, id ->
        ReminderAction(id, labels.getOrNull(index) ?: id)
    }
    return Reminder(
        taskId = taskId,
        title = intent.getStringExtra(ReminderExtras.TITLE).orEmpty(),
        body = intent.getStringExtra(ReminderExtras.BODY),
        channel = ReminderChannel.fromName(intent.getStringExtra(ReminderExtras.CHANNEL)),
        fullScreen = intent.getBooleanExtra(ReminderExtras.FULL_SCREEN, false),
        actions = actions,
    )
}

// -------------------------------------------------------------- 事件持久队列

/**
 * 原生 → Dart 事件队列：SharedPreferences 里的 JSON 数组，进程重启后依然可捞回。
 *
 * 契约：事件要么直投、要么入队，绝不两者都做；[publish] 是唯一入口，
 * 它内部按"有直投通道 → 直投；否则入队"的顺序保证恰好一次。
 */
object NativeEventQueue {

    private const val PREFS = "gtd_native_events"
    private const val KEY_EVENTS = "events"

    private val lock = Any()

    /** 由 [NativeBridge] 注入：返回 true 表示已直投，无须入队。 */
    @Volatile
    private var directDeliverer: ((Map<String, Any?>) -> Boolean)? = null

    fun setDirectDeliverer(deliverer: (Map<String, Any?>) -> Boolean) {
        directDeliverer = deliverer
    }

    fun clearDirectDeliverer() {
        directDeliverer = null
    }

    /** 投递一个事件：能直投就直投，否则落到持久队列。 */
    fun publish(context: Context, event: Map<String, Any?>) {
        val deliver = directDeliverer
        if (deliver != null && deliver(event)) return
        enqueue(context, event)
    }

    private fun enqueue(context: Context, event: Map<String, Any?>) {
        synchronized(lock) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val array = readArray(prefs.getString(KEY_EVENTS, null))
            array.put(JSONObject(event as Map<*, *>))
            prefs.edit().putString(KEY_EVENTS, array.toString()).commit()
        }
    }

    /** 取走全部待处理事件并清空队列；返回类型即 MethodChannel 的 List<Map>。 */
    fun drain(context: Context): List<Map<String, Any?>> {
        synchronized(lock) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val array = readArray(prefs.getString(KEY_EVENTS, null))
            if (array.length() == 0) return emptyList()
            val out = ArrayList<Map<String, Any?>>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                out += jsonToMap(obj)
            }
            prefs.edit().remove(KEY_EVENTS).commit()
            return out
        }
    }

    /** 仅供排队（接收器在无 Activity 场景下也可直接调）。 */
    fun enqueueOnly(context: Context, event: Map<String, Any?>) = enqueue(context, event)

    private fun readArray(raw: String?): JSONArray = try {
        if (raw.isNullOrEmpty()) JSONArray() else JSONArray(raw)
    } catch (_: Throwable) {
        JSONArray()
    }

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = obj.opt(key)
            map[key] = if (value == JSONObject.NULL) null else value
        }
        return map
    }
}
