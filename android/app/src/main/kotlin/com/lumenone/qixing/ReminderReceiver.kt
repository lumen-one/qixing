package com.lumenone.qixing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/**
 * 系统闹钟到点时的落地点（进程可能完全没起来）。
 *
 * 职责：起铃（闹钟渠道）→ 投递通知 → 把站点表这一格标成已投 → 给 Dart 发
 * `alarmFired` 事件。**不重排闹钟**：其余站点在挂表时就各自挂好了。
 *
 * **不判断"该不该响"**：这一条走哪个渠道、是不是时点提醒，全由 Dart 在挂闹钟那一刻
 * 写进 [ReminderDraft] 的草案决定，这里只照草案执行（应用被杀时它是唯一的信息来源）。
 */
class ReminderReceiver : BroadcastReceiver() {

    companion object {
        /** 空闲闹钟用的固定 action，是 PendingIntent 身份的一部分（见 alarmIntent）。 */
        const val ACTION_REMINDER_ALARM = "com.lumenone.qixing.action.REMINDER_ALARM"

        /** 缺 `seconds` 时的兜底，与 Dart 侧 `defaultAlarmRingSeconds` 同值。 */
        private const val DEFAULT_RING_SECONDS = 60

        /** 通知按钮的 requestCode 派生规则，Dart 侧不需要知道，但必须与 Notifier 一致。 */
        fun actionRequestCode(taskId: String, index: Int): Int {
            var code = 31 * taskId.hashCode() + index
            // 与闹钟的 requestCode 0 错开，避免 PendingIntent "身份"撞车。
            if (code == 0) code = 1
            return code
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REMINDER_ALARM) return
        val app = context.applicationContext
        val reminder = reminderFromIntent(intent)
        if (reminder.taskId.isEmpty()) {
            Log.w("gtd", "ReminderReceiver got an alarm without taskId, ignored")
            return
        }

        // 闹钟唤醒瞬间拿一段短 wakelock，确保通知真的投递出去。
        val wakeLock = acquireWakeLock(app)
        try {
            val delivery = prepareDelivery(app, intent, reminder)
            val posted = Notifier.post(app, delivery.reminder, ringing = delivery.ringing)
            Log.i(
                "gtd",
                "alarm fired taskId=${delivery.reminder.taskId} posted=$posted ringing=${delivery.ringing}",
            )
            if (delivery.ringing) showPage(app, delivery.reminder)
            // 这一站投过了：开机恢复时别再补投一遍。主键由站点表在挂钟时写进 extras，
            // 老版本闹钟没有这个字段，markFired 会安静地什么都不做。
            AlarmStationStore.markFired(
                app,
                intent.getStringExtra(ReminderExtras.STATION_KEY),
            )
            // `delivered` 告诉 Dart 侧"这条已经弹过了"：Dart 只记账与排下一站，
            // 不再 show 一次（同 id 替换会重新响铃、把通知时刻刷成"现在"）。
            // 应用被杀时事件先进队列，等下次启动才被取走——那时更不能重弹。
            NativeEventQueue.publish(
                app,
                mapOf(
                    "type" to "alarmFired",
                    "taskId" to reminder.taskId,
                    "delivered" to posted,
                ),
            )
        } catch (t: Throwable) {
            Log.w("gtd", "alarm handling failed: ${t.message}", t)
        } finally {
            releaseWakeLock(wakeLock)
        }
    }

    /**
     * 到点这一刻的交付：投哪一份草案、要不要按"正在响铃"投。
     *
     * [ringing] 是**实际结果**，不是意图：起不来前台服务时只投普通通知（没有
     * ongoing、没有全屏页），否则用户会看到一条划不走、点开是空白页的假闹钟。
     */
    private data class Delivery(val reminder: Reminder, val ringing: Boolean)

    /**
     * 到点这一刻原生才知道的几件事：有没有弹页的权限、要不要起铃、这一分钟是不是
     * 已经有过一个页面。
     *
     * 同一分钟的第二件（[AlarmRingService.claimPageMinute] 为 false）只投普通通知——
     * 全屏页同一刻只能有一个抢到前台，第二股铃声也只是叠音。它自己的 `point_fired`
     * 与下一站照旧由 Dart 记账，提醒不会丢。
     */
    private fun prepareDelivery(app: Context, intent: Intent, reminder: Reminder): Delivery {
        if (reminder.channel != ReminderChannel.ALARM) return Delivery(reminder, false)
        // 全屏/锁屏显示权限被拒（Android 14 起可选、ColorOS 默认常关）只影响**页面**：
        // 照常起铃，停止键本来就在通知的动作按钮上（Notifier 的 stopRingIntent）。
        // 以前这里连铃一起降级，OPPO 上就成了"闹钟完全不响"。showPage 自己会再判一次。
        if (!Notifier.canUseFullScreenIntent(app)) {
            Log.i("gtd", "no full-screen page permission, ring anyway taskId=${reminder.taskId}")
        }
        if (!AlarmRingService.claimPageMinute(app)) {
            Log.i("gtd", "same minute already has an alarm page, degrade taskId=${reminder.taskId}")
            return Delivery(
                reminder.copy(channel = ReminderChannel.RING, fullScreen = false),
                false,
            )
        }
        val seconds = intent.getIntExtra(ReminderExtras.RING_SECONDS, DEFAULT_RING_SECONDS)
        val ringing = AlarmRingService.start(app, reminder, seconds)
        Log.i("gtd", "ring start taskId=${reminder.taskId} seconds=$seconds ok=$ringing")
        return Delivery(reminder, ringing)
    }

    /**
     * 直接把全屏页拉起来（手里正拿着手机时，full-screen intent 只会变成横幅）。
     *
     * 后台启动 Activity 在 Android 10+ 受限：有悬浮窗权限（本应用常态）或系统认这条
     * 精确闹钟时放行，其余情形静默失败——通知上的 full-screen intent 还在，锁屏/灭屏
     * 照样会拉起。被拦不是错误，所以只记日志。
     */
    private fun showPage(app: Context, reminder: Reminder) {
        if (!Notifier.canUseFullScreenIntent(app)) return
        try {
            app.startActivity(AlarmActivity.intent(app, reminder))
        } catch (t: Throwable) {
            Log.w("gtd", "alarm page start blocked: ${t.message}")
        }
    }

    private fun acquireWakeLock(context: Context): PowerManager.WakeLock? = try {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gtd:reminder")?.apply {
            setReferenceCounted(false)
            acquire(10_000L)
        }
    } catch (t: Throwable) {
        Log.w("gtd", "wakelock acquire failed: ${t.message}")
        null
    }

    private fun releaseWakeLock(lock: PowerManager.WakeLock?) {
        try {
            if (lock != null && lock.isHeld) lock.release()
        } catch (_: Throwable) {
            // 忽略：wakelock 释放失败不影响通知已经投递的事实。
        }
    }
}
