package com.lumenone.qixing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 系统通知的唯一出口：闹钟触发（[ReminderReceiver]）与立即预览
 * （`showNotification`）都经由这里投递。
 *
 * 设计要点（与 Dart 侧契约一致）：
 * - 通知 id = taskId.hashCode()，同一任务重复投递是"替换"而非"堆叠"；
 * - 两个渠道在首次使用时创建：gtd_normal（默认）/ gtd_alarm（高优先级 + 震动）；
 * - 未授予 POST_NOTIFICATIONS 时 [post] 返回 false，绝不抛异常。
 */
object Notifier {

    const val CHANNEL_RING = "gtd_ring"
    const val CHANNEL_SILENT = "gtd_silent"
    const val CHANNEL_ALARM = "gtd_alarm"
    const val CHANNEL_OVERLAY = "gtd_overlay"

    /**
     * 响铃时那条**前台服务**通知的渠道：服务本身只需要"有个常驻条目"，声音由
     * [AlarmRingService] 的 MediaPlayer 承担。挂在 `gtd_alarm` 上会变成两条通知各响一遍。
     */
    const val CHANNEL_RINGING = "gtd_ringing"

    /** 旧版本的普通通知渠道：渠道属性（重要性、声音）建完就不可改，只能删掉换新 id。 */
    private const val CHANNEL_LEGACY_NORMAL = "gtd_normal"

    private const val CHANNEL_RING_NAME = "任务提醒"
    private const val CHANNEL_SILENT_NAME = "任务提醒（静音）"
    private const val CHANNEL_ALARM_NAME = "闹钟提醒"
    private const val CHANNEL_OVERLAY_NAME = "悬浮手柄"
    private const val CHANNEL_RINGING_NAME = "正在响铃"

    /** 悬浮手柄常驻通知用固定 id（与任务通知的 hashCode 空间不冲突的负数）。 */
    const val OVERLAY_NOTIFICATION_ID = -0x0F10

    private val VIBRATION_PATTERN = longArrayOf(0L, 400L, 200L, 400L)

    /** 『停止响铃』按钮的 requestCode 下标：与 done / snooze 的下标错开，别撞 PendingIntent。 */
    private const val STOP_RING_ACTION_INDEX = 99

    /** 通知 id 的稳定映射：跨进程重启后仍是同一任务同一 id。 */
    fun notificationId(taskId: String): Int = taskId.hashCode()

    /** 渠道创建是幂等的，可以每次投递前都调一次。 */
    fun ensureChannels(context: Context, overlay: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val app = context.applicationContext

        // 旧渠道删掉：留着会让系统设置里出现两个"任务提醒"，而且旧的 IMPORTANCE_DEFAULT
        // 不弹横幅。删频道会连带清掉用户在上面调过的手动设置，这是渠道不可变的代价。
        manager.deleteNotificationChannel(CHANNEL_LEGACY_NORMAL)

        // 有声：IMPORTANCE_HIGH = 横幅必现；声音 + 震动都挂在渠道上。
        if (manager.getNotificationChannel(CHANNEL_RING) == null) {
            val channel = NotificationChannel(CHANNEL_RING, CHANNEL_RING_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(true)
            channel.vibrationPattern = VIBRATION_PATTERN
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            val audio = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .build()
            channel.setSound(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI, audio)
            manager.createNotificationChannel(channel)
        }
        // 静音：同一个重要性（横幅照弹），但没有声音与震动。
        if (manager.getNotificationChannel(CHANNEL_SILENT) == null) {
            val channel = NotificationChannel(CHANNEL_SILENT, CHANNEL_SILENT_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(false)
            channel.setSound(null, null)
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }
        if (manager.getNotificationChannel(CHANNEL_ALARM) == null) {
            val channel = NotificationChannel(CHANNEL_ALARM, CHANNEL_ALARM_NAME, NotificationManager.IMPORTANCE_HIGH)
            channel.enableVibration(true)
            channel.vibrationPattern = VIBRATION_PATTERN
            channel.setShowBadge(true)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            val audio = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_ALARM)
                .build()
            channel.setSound(android.provider.Settings.System.DEFAULT_ALARM_ALERT_URI, audio)
            manager.createNotificationChannel(channel)
        }
        // 悬浮手柄的常驻通知必须是最低打扰：静音、不震动、不打扰锁屏。
        if (overlay && manager.getNotificationChannel(CHANNEL_OVERLAY) == null) {
            val channel = NotificationChannel(CHANNEL_OVERLAY, CHANNEL_OVERLAY_NAME, NotificationManager.IMPORTANCE_MIN)
            channel.setShowBadge(false)
            channel.enableVibration(false)
            channel.lockscreenVisibility = Notification.VISIBILITY_SECRET
            manager.createNotificationChannel(channel)
        }
        // 响铃中的前台服务通知：可见但安静（声音归 MediaPlayer，不归渠道）。
        if (manager.getNotificationChannel(CHANNEL_RINGING) == null) {
            val channel = NotificationChannel(CHANNEL_RINGING, CHANNEL_RINGING_NAME, NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            channel.enableVibration(false)
            channel.setSound(null, null)
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }
    }

    /** 悬浮手柄前台服务的常驻通知（低优先级、无声音、不可划走）。 */
    fun buildOverlayNotification(context: Context): Notification {
        ensureChannels(context, overlay = true)
        val contentIntent = PendingIntent.getActivity(
            context,
            0x0F10,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_OPEN_PANEL, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL_OVERLAY)
            .setSmallIcon(R.drawable.ic_notify_star)
            .setContentTitle("启行")
            .setContentText("悬浮手柄已开启，点按可打开面板")
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .build()
    }

    /**
     * 投递（或替换）一条任务通知。
     *
     * @param ringing 这一条此刻**正在响铃**：置 ongoing（划不走）、挂全屏页与『停止响铃』。
     *   停声后重投时传 false——通知留在栏里，只恢复成可划走（ui-interaction.md §7.2）。
     *   缺省按渠道判断：闹钟渠道默认在响，普通渠道根本没有"响铃"这回事。
     * @return 真正交给系统返回 true；缺权限、渠道被禁用等软失败返回 false。
     */
    fun post(
        context: Context,
        reminder: Reminder,
        ringing: Boolean = reminder.channel == ReminderChannel.ALARM,
    ): Boolean = try {
        ensureChannels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            false
        } else {
            manager.notify(notificationId(reminder.taskId), build(context, reminder, ringing))
            true
        }
    } catch (_: Throwable) {
        // 任何厂商 ROM 的 SecurityException / 引擎异常都不应打断闹钟链路。
        false
    }

    fun cancel(context: Context, taskId: String): Boolean = try {
        NotificationManagerCompat.from(context).cancel(notificationId(taskId))
        true
    } catch (_: Throwable) {
        false
    }

    /**
     * 响铃时的**前台服务通知**（[AlarmRingService] 用）。
     *
     * 它只是"服务在跑"的凭据：静音、常驻、点开回到全屏页。声音由 MediaPlayer 承担，
     * 这里再挂到 `gtd_alarm` 渠道就是两条通知各响一遍。
     */
    fun buildRingingNotification(context: Context, reminder: Reminder): Notification {
        ensureChannels(context)
        return NotificationCompat.Builder(context, CHANNEL_RINGING)
            .setSmallIcon(R.drawable.ic_notify_star)
            .setContentTitle(reminder.title)
            .setContentText(reminder.body ?: "正在响铃")
            .setContentIntent(pageIntent(context, reminder))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .build()
    }

    /** 全屏闹钟页（[AlarmActivity]）的 PendingIntent：全屏 intent 与前台服务通知共用。 */
    private fun pageIntent(context: Context, reminder: Reminder): PendingIntent =
        PendingIntent.getActivity(
            context,
            notificationId(reminder.taskId) + 1,
            AlarmActivity.intent(context, reminder),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * 通知上的『停止响铃』：走 [ActionReceiver] 的专用 action。
     *
     * 刻意不复用 `done` / `snooze1h` 那两个 id——停声不动任务状态，Dart 那边没有事要做；
     * 但要把整条提醒带上，停完之后才重投得出"可划走"的那一份。
     */
    private fun stopRingIntent(context: Context, reminder: Reminder): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            ReminderReceiver.actionRequestCode(reminder.taskId, STOP_RING_ACTION_INDEX),
            Intent(context, ActionReceiver::class.java).apply {
                setAction(ActionReceiver.ACTION_RING_STOP)
                putReminderExtras(reminder)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun build(context: Context, reminder: Reminder, ringing: Boolean): Notification {
        val alarm = reminder.channel == ReminderChannel.ALARM
        val channelId = when (reminder.channel) {
            ReminderChannel.ALARM -> CHANNEL_ALARM
            ReminderChannel.SILENT -> CHANNEL_SILENT
            ReminderChannel.RING -> CHANNEL_RING
        }
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notify_star)
            .setContentTitle(reminder.title)
            .setContentText(reminder.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(reminder.body ?: reminder.title))
            .setAutoCancel(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)

        // 内容点击 → MainActivity，带 focusTaskId 供 Dart 定位任务。
        // 注意：这里刻意不写 actionId，避免与 ActionReceiver 的语义混淆。
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationId(reminder.taskId),
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(MainActivity.EXTRA_FOCUS_TASK_ID, reminder.taskId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        builder.setContentIntent(contentIntent)

        if (alarm) {
            builder.setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                // 同一条通知会被投不止一次（原生接收器 + Dart 补投、停声后再投一次）：
                // 只有第一次该出声，后面几次只是改内容。
                .setOnlyAlertOnce(true)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
            // 震动由 gtd_alarm 渠道承载（O+）；低版本由 setDefaults 兜底。
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                builder.setVibrate(VIBRATION_PATTERN)
            }
            if (ringing) {
                // 响铃中：划不走，点开就是全屏页。停声后走 else 那一支放开。
                builder.setOngoing(true)
                if (reminder.fullScreen && canUseFullScreenIntent(context)) {
                    builder.setFullScreenIntent(pageIntent(context, reminder), true)
                }
                builder.addAction(0, "停止响铃", stopRingIntent(context, reminder))
            } else {
                builder.setOngoing(false)
            }
        } else {
            // 横幅靠渠道重要性（O+）；O 以下靠 PRIORITY_HIGH。静音那条只掐声音与震动。
            builder.setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
            if (reminder.channel == ReminderChannel.SILENT) {
                builder.setSilent(true).setDefaults(0)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    builder.setVibrate(longArrayOf(0L))
                }
            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                builder.setDefaults(NotificationCompat.DEFAULT_ALL)
                builder.setVibrate(VIBRATION_PATTERN)
            }
        }

        reminder.actions.forEachIndexed { index, action ->
            val actionIntent = PendingIntent.getBroadcast(
                context,
                ReminderReceiver.actionRequestCode(reminder.taskId, index),
                Intent(context, ActionReceiver::class.java).apply {
                    // 固定 action 串，保证 PendingIntent 身份稳定（extras 不参与匹配）。
                    setAction(ActionReceiver.ACTION_REMINDER_ACTION)
                    putExtra(ReminderExtras.TASK_ID, reminder.taskId)
                    putExtra(ActionReceiver.EXTRA_ACTION_ID, action.id)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(0, action.label, actionIntent)
        }
        return builder.build()
    }

    /** Android 14 起全屏意图成为可选权限，未授予时只能退化成普通通知。 */
    fun canUseFullScreenIntent(context: Context): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            true
        } else {
            try {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.canUseFullScreenIntent()
            } catch (_: Throwable) {
                false
            }
        }
}
