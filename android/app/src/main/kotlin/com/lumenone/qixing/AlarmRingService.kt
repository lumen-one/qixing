package com.lumenone.qixing

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * 持续响铃：`AlarmRingPort` 的安卓执行侧（ui-interaction.md §7.2 / sockets/delivery.md）。
 *
 * 与通知分开的一条通道——通知是"留在那儿的消息"，铃声是"现在就要你注意"。所以本服务
 * 只管发声：**投递通知的不是它**（应用活着走 [ReminderReceiver] 的草案，应用被杀也走
 * 那条），它只负责
 *
 * - 循环播放系统闹钟音（`USAGE_ALARM`，媒体静音压不住）+ `mediaPlayback` 前台服务 +
 *   `PARTIAL_WAKE_LOCK`：锁屏、息屏、应用被杀三条路径都要出声；
 * - 到 `seconds` 秒自停（默认 60，Dart 侧 `alarm_ring_seconds` 夹在 15–300）；
 *   同一件重复 start = **续期**，不叠第二股声音、不重建播放器；
 * - 停声后把那条任务通知投成"可划走"（[Notifier.post] 的 `ringing = false`），
 *   通知本身留在栏里——这是"停声"与"撤掉提醒"的区别。
 *
 * 起不来的情形（Android 12+ 后台启动前台服务受限、厂商拦截、没有通知权限）不抛异常：
 * [start] 回 false，调用方照旧投通知栏 + 横幅 + 提示音，这条代价登记在
 * architecture.md §11。
 */
class AlarmRingService : Service() {

    companion object {
        const val ACTION_START = "com.lumenone.qixing.action.RING_START"
        const val ACTION_STOP = "com.lumenone.qixing.action.RING_STOP"

        private const val TAG = "gtd"

        /** 前台服务通知的 id：与任务通知（taskId.hashCode）不在一个空间。 */
        private const val NOTIFICATION_ID = -0x0F11

        /** 缺 `seconds` 时的兜底（与 Dart 侧 `defaultAlarmRingSeconds` 同值）。 */
        private const val DEFAULT_SECONDS = 60

        /** 再短就不像闹钟了：`seconds` 来自 Intent extras，防一手脏值。 */
        private const val MIN_SECONDS = 5

        /** 「同一分钟只起一个闹钟页」的落点：跨进程重启也要记得，所以进 prefs。 */
        private const val PREFS = "gtd_alarm_ring"
        private const val KEY_PAGE_MINUTE = "page_minute"

        /** 当前活着的服务（同进程直接调用，省一次 startService）。 */
        @Volatile
        private var live: AlarmRingService? = null

        /** 正在响的那一件；null = 没在响。供 Dart 端口与停止按钮判断。 */
        @Volatile
        var ringingTaskId: String? = null
            private set

        /**
         * 起铃 / 续期。
         *
         * @return true = 前台服务已经拉起来；false = 系统拒绝（后台启动受限等），
         *         调用方按"只投通知"降级。
         */
        fun start(context: Context, reminder: Reminder, seconds: Int): Boolean {
            val app = context.applicationContext
            val intent = Intent(app, AlarmRingService::class.java).apply {
                action = ACTION_START
                putReminderExtras(reminder)
                putExtra(ReminderExtras.RING_SECONDS, seconds)
            }
            return try {
                ContextCompat.startForegroundService(app, intent)
                true
            } catch (t: Throwable) {
                Log.w(TAG, "ring start rejected: ${t.message}", t)
                false
            }
        }

        /** 只停服务（声音、wakelock、前台通知一起收），不碰任务通知。 */
        fun stop(context: Context) {
            val app = context.applicationContext
            try {
                app.stopService(Intent(app, AlarmRingService::class.java))
            } catch (t: Throwable) {
                Log.w(TAG, "ring stop failed: ${t.message}")
            }
        }

        /**
         * 手动『停止响铃』（全屏页 / 通知按钮）：停声 + 那条通知恢复成可划走。
         *
         * 服务不在时（已被系统回收）也要把通知放开——否则一条 ongoing 通知会永远赖在栏里。
         */
        fun stopByUser(context: Context, reminder: Reminder) {
            val app = context.applicationContext
            if (live == null) Notifier.post(app, reminder, ringing = false)
            stop(app)
        }

        /** 完成 / 推迟：通知由 [ActionReceiver] 撤掉，服务侧不再补投一条回来。 */
        fun stopForAction(context: Context) {
            live?.repostOnStop = false
            stop(context)
        }

        /**
         * 这一分钟还能不能再起一个全屏页。true = 可以（并已记账）；false = 本分钟已有页。
         *
         * 同一分钟里的第二件到点时，只需普通通知：全屏页同一刻只能有一个抢到前台，
         * 第二股铃声也只是叠音。判据只看"这一分钟起过没有"，与任务是谁无关。
         */
        fun claimPageMinute(context: Context): Boolean {
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val minute = System.currentTimeMillis() / 60_000L
            if (prefs.getLong(KEY_PAGE_MINUTE, -1L) == minute) return false
            prefs.edit().putLong(KEY_PAGE_MINUTE, minute).apply()
            return true
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    /** 到时候自己停：只在"起铃"时挂一次，续期时重置。 */
    private val autoStop = Runnable { stopSelf() }

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    /** 起铃时那一件的交付内容：停声后按它把通知重投成可划走。 */
    private var reminder: Reminder? = null

    /** false = 这次是"完成 / 推迟"，通知要被撤掉，别在 onDestroy 里补投回来。 */
    private var repostOnStop = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_STOP -> {
                repostOnStop = true
                stopSelf()
            }

            ACTION_START -> {
                val reminder = reminderFromIntent(intent)
                if (reminder.taskId.isEmpty()) {
                    Log.w(TAG, "ring start without taskId, ignored")
                    stopSelf()
                    return START_NOT_STICKY
                }
                val seconds = intent.getIntExtra(ReminderExtras.RING_SECONDS, DEFAULT_SECONDS)
                    .coerceAtLeast(MIN_SECONDS)
                begin(reminder, seconds)
            }

            else -> stopSelf()
        }
        // 不复活：进程被回收时铃声已经没了，重启一个"没在响的服务"只会留一条假通知。
        return START_NOT_STICKY
    }

    private fun begin(reminder: Reminder, seconds: Int) {
        live = this
        repostOnStop = true
        // 同一件重复 start = 续期：声音不断、不重建播放器，只把自停与 wakelock 往后推。
        val sameTask = this.reminder?.taskId == reminder.taskId && player != null
        this.reminder = reminder
        ringingTaskId = reminder.taskId
        if (!promoteToForeground(reminder)) {
            // 起不了前台服务：`startForegroundService` 之后 5 秒内不升前台会被系统判
            // ANR，所以这里只能自己停。声音留给通知那条路（调用方照草案投的是普通通知）。
            Log.w(TAG, "ring abandoned: cannot become a foreground service")
            stopSelf()
            return
        }
        if (!sameTask) startPlayer()
        holdWakeLock(seconds)
        handler.removeCallbacks(autoStop)
        handler.postDelayed(autoStop, seconds * 1000L)
    }

    /**
     * 升成前台服务。
     *
     * 必须**先**叫 `startForeground` 再播：顺序反了，"启动受限"会直接变成崩溃。
     *
     * @return false = 系统/厂商拒绝（缺前台服务类型权限、后台启动被拦），调用方停手。
     */
    private fun promoteToForeground(reminder: Reminder): Boolean {
        val notification = Notifier.buildRingingNotification(this, reminder)
        return try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
            true
        } catch (t: Throwable) {
            Log.w(TAG, "startForeground failed: ${t.message}", t)
            false
        }
    }

    private fun startPlayer() {
        releasePlayer()
        val uri = Settings.System.DEFAULT_ALARM_ALERT_URI
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: return
        player = try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(this@AlarmRingService, uri)
                isLooping = true
                // 屏幕熄灭/Doze 时 CPU 会被挂起，声音跟着断——播放器自己持一把。
                setWakeMode(this@AlarmRingService, PowerManager.PARTIAL_WAKE_LOCK)
                prepare()
                start()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "ringtone playback failed: ${t.message}", t)
            null
        }
    }

    private fun holdWakeLock(seconds: Int) {
        releaseWakeLock()
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = try {
            power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gtd:alarm-ring").apply {
                setReferenceCounted(false)
                acquire(seconds * 1000L + 10_000L)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "ring wakelock failed: ${t.message}")
            null
        }
    }

    private fun releasePlayer() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Throwable) {
            // 释放失败只可能是播放器已经坏了；不该让服务因此崩掉。
        }
        player = null
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
            // 同上：释放失败不影响"已经停声"这个事实。
        }
        wakeLock = null
    }

    override fun onDestroy() {
        handler.removeCallbacks(autoStop)
        releasePlayer()
        releaseWakeLock()

        val pending = reminder
        val wasRinging = ringingTaskId != null
        reminder = null
        ringingTaskId = null
        if (live === this) live = null

        if (wasRinging) {
            // 停声 ≠ 撤掉提醒：那条通知留在栏里，只是恢复成能划走（§7.2）。
            if (repostOnStop && pending != null) {
                Notifier.post(this, pending, ringing = false)
            }
            // 让 Dart 侧那一份 AlarmRingPort 知道"已经不响了"（它在起铃时记了 taskId）。
            if (NativeBridge.activeInstance != null) {
                NativeEventQueue.publish(
                    this,
                    mapOf("type" to "ringStopped", "taskId" to (pending?.taskId ?: "")),
                )
            }
        }

        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
