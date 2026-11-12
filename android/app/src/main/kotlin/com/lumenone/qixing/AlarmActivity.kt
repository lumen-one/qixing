package com.lumenone.qixing

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView

/**
 * 全屏闹钟页（ui-interaction.md §7.2）：独立 Activity，**不拉起 [MainActivity]**。
 *
 * 为什么不做进 Flutter：应用被杀时那一套引擎/数据都没起来，而这条路径恰恰是闹钟最需要
 * 走通的路径（锁屏、息屏、后台）。这里只用系统控件画标题 + 正文 + 三个动作，进程一醒
 * 就能显示。
 *
 * 三个动作：
 * - 『停止响铃』→ 广播给 [ActionReceiver]（停声，通知留在栏里恢复成可划走）；
 * - 『完成』『推迟 1 小时』→ 同通知按钮那条链路（撤通知 + 回事件给 Dart，应用没开则入队）。
 *
 * 锁屏与息屏靠 `showWhenLocked` / `turnScreenOn`（API 27+）与旧窗口 flag 双写；
 * 系统不给全屏 intent 权限时这个页根本不会被拉起，那是 [Notifier] 那边的降级判断。
 */
class AlarmActivity : Activity() {

    companion object {
        private const val TAG = "gtd"

        /** 全屏 intent 与进程内直拉共用的 intent：带上这条提醒的全部渲染数据。 */
        fun intent(context: Context, reminder: Reminder): Intent =
            Intent(context, AlarmActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                putReminderExtras(reminder)
            }
    }

    private var reminder: Reminder? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        setContentView(R.layout.activity_alarm)
        bindButtons()
        render(intent)
    }

    /** 同一分钟之后的第二件不会再起页；真起了（换了一件）就地把文案换掉。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        render(intent)
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
    }

    private fun bindButtons() {
        findViewById<Button>(R.id.alarm_stop).setOnClickListener { stopRinging() }
        findViewById<Button>(R.id.alarm_done).setOnClickListener { sendAction("done") }
        findViewById<Button>(R.id.alarm_snooze).setOnClickListener { sendAction("snooze1h") }
    }

    private fun render(intent: Intent) {
        val parsed = reminderFromIntent(intent)
        if (parsed.taskId.isEmpty()) {
            Log.w(TAG, "alarm page without taskId, closing")
            finish()
            return
        }
        reminder = parsed
        findViewById<TextView>(R.id.alarm_title).text = parsed.title
        val body = findViewById<TextView>(R.id.alarm_body)
        if (parsed.body.isNullOrBlank()) {
            body.visibility = View.GONE
        } else {
            body.text = parsed.body
            body.visibility = View.VISIBLE
        }
    }

    private fun stopRinging() {
        val current = reminder
        if (current != null) {
            sendBroadcast(
                Intent(this, ActionReceiver::class.java).apply {
                    action = ActionReceiver.ACTION_RING_STOP
                    putReminderExtras(current)
                }
            )
        }
        finish()
    }

    private fun sendAction(actionId: String) {
        val current = reminder ?: return
        sendBroadcast(
            Intent(this, ActionReceiver::class.java).apply {
                action = ActionReceiver.ACTION_REMINDER_ACTION
                putExtra(ReminderExtras.TASK_ID, current.taskId)
                putExtra(ActionReceiver.EXTRA_ACTION_ID, actionId)
            }
        )
        finish()
    }

    /** 返回键 = 停止响铃再退出，别把铃声留在后台一直响。 */
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        stopRinging()
    }
}
