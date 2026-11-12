package com.lumenone.qixing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 通知按钮（done / snooze1h）与『停止响铃』的落地点。
 *
 * - 任务动作：撤销该任务的通知、停掉正在响的那股铃（如果就是这一件）、把 `action`
 *   事件交给 Dart。刻意不启动 Activity —— 点按钮不应该把用户从当前界面拽走。
 * - [ACTION_RING_STOP]（通知 / 全屏页上的『停止响铃』）：只停声，任务状态一个字不动，
 *   也不回事件——Dart 那边没有事要做。停完通知留在栏里，恢复成可划走。
 */
class ActionReceiver : BroadcastReceiver() {

    companion object {
        /** PendingIntent 身份的一部分；固定值，避免每次投递产生新 PendingIntent。 */
        const val ACTION_REMINDER_ACTION = "com.lumenone.qixing.action.REMINDER_ACTION"

        /**
         * 『停止响铃』的专用 action。
         *
         * 不复用 `done` / `snooze1h` 那两个 id：那两个会改任务状态并经 Dart 回传，
         * 而停声是纯原生的一件事（全屏页与通知按钮都走它）。
         */
        const val ACTION_RING_STOP = "com.lumenone.qixing.action.RING_STOP"

        const val EXTRA_ACTION_ID = "actionId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        when (intent.action) {
            ACTION_RING_STOP -> {
                val reminder = reminderFromIntent(intent)
                if (reminder.taskId.isEmpty()) {
                    Log.w("gtd", "ActionReceiver stop without taskId, ignored")
                    return
                }
                try {
                    AlarmRingService.stopByUser(app, reminder)
                    Log.i("gtd", "stop ringing taskId=${reminder.taskId}")
                } catch (t: Throwable) {
                    Log.w("gtd", "stop ringing failed: ${t.message}", t)
                }
                return
            }

            ACTION_REMINDER_ACTION -> Unit

            else -> return
        }

        val taskId = intent.getStringExtra(ReminderExtras.TASK_ID)
        val actionId = intent.getStringExtra(EXTRA_ACTION_ID)
        if (taskId.isNullOrEmpty() || actionId.isNullOrEmpty()) {
            Log.w("gtd", "ActionReceiver missing taskId/actionId, ignored")
            return
        }
        try {
            Notifier.cancel(app, taskId)
            // 正在响的就是这一件：连声音一起收。通知刚撤掉，服务侧不用再补投一条回来。
            if (AlarmRingService.ringingTaskId == taskId) {
                AlarmRingService.stopForAction(app)
            }
            Log.i("gtd", "action=$actionId taskId=$taskId")
            NativeEventQueue.publish(
                app,
                mapOf("type" to "action", "actionId" to actionId, "taskId" to taskId),
            )
        } catch (t: Throwable) {
            Log.w("gtd", "action handling failed: ${t.message}", t)
        }
    }
}
