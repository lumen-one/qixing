package com.lumenone.qixing

import android.content.Intent

/**
 * 一条提醒的全部渲染数据（原生侧 DTO）。
 *
 * 由 MethodChannel `gtd/native` 的 scheduleAlarm / showNotification 参数构造，
 * 经 PendingIntent extras 在闹钟触发时原样传给 [ReminderReceiver]。
 * Dart 侧会持续发相同字段，这里只做搬运，不做业务判断。
 */
data class Reminder(
    val taskId: String,
    val title: String,
    val body: String?,
    val channel: ReminderChannel,
    val fullScreen: Boolean,
    val actions: List<ReminderAction>,
)

/**
 * 通知渠道三档（与 Dart 侧 `ReminderChannel` 同名同序）：
 * - [RING] 有声 + 震动，IMPORTANCE_HIGH（横幅必现）；
 * - [SILENT] 同样 IMPORTANCE_HIGH、横幅照弹，但没有声音与震动；
 * - [ALARM] 全屏 + 持续响铃，只在设置页开了『闹钟模式』的时点提醒上用。
 */
enum class ReminderChannel {
    RING, SILENT, ALARM;

    companion object {
        /**
         * 渠道名。两个来源写法不同：Dart 经 MethodChannel 传的是小写枚举名
         * （`ring` / `silent` / `alarm`），Intent extras 里写的是 `name.lowercase()`。
         * 这里统一按小写认——以前只认小写，而 [putReminderExtras] 写的是大写枚举名，
         * 结果闹钟过一趟广播就退化成 `ring`（提示音不是闹钟音、也不起铃）。
         */
        fun fromName(name: String?): ReminderChannel = when (name?.lowercase()) {
            "silent" -> SILENT
            "alarm" -> ALARM
            else -> RING
        }
    }
}

/** 通知按钮：id 回到 Dart（`done` / `snooze1h`），label 只用于显示。 */
data class ReminderAction(val id: String, val label: String)

/** Intent extras 的键名集中在此，避免收发两端写错字符串。 */
object ReminderExtras {
    const val TASK_ID = "taskId"
    const val TITLE = "title"
    const val BODY = "body"
    const val CHANNEL = "channel"
    const val FULL_SCREEN = "fullScreen"
    const val ACTION_IDS = "actionIds"
    const val ACTION_LABELS = "actionLabels"

    /**
     * 响铃时长（秒）：挂闹钟时由 Dart 一起写进来（见 `AlarmRingService.start` /
     * `NativeBridge.scheduleAlarm`）。应用被杀时接收器没有别的地方问这个值——
     * 手机上的 `settings.json` 归 Dart 那一层读。
     */
    const val RING_SECONDS = "ringSeconds"
}

/**
 * 把一条提醒写进 Intent extras（闹钟广播、全屏页、停止响铃按钮共用同一份形状）。
 *
 * 这几个入口都会在进程里"从零还原"这条提醒（没有 Dart、没有内存对象），所以必须写全。
 */
internal fun Intent.putReminderExtras(reminder: Reminder) {
    putExtra(ReminderExtras.TASK_ID, reminder.taskId)
    putExtra(ReminderExtras.TITLE, reminder.title)
    putExtra(ReminderExtras.BODY, reminder.body)
    putExtra(ReminderExtras.CHANNEL, reminder.channel.name.lowercase())
    putExtra(ReminderExtras.FULL_SCREEN, reminder.fullScreen)
    putStringArrayListExtra(ReminderExtras.ACTION_IDS, ArrayList(reminder.actions.map { it.id }))
    putStringArrayListExtra(ReminderExtras.ACTION_LABELS, ArrayList(reminder.actions.map { it.label }))
}
