package com.lumenone.qixing

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 站点表在原生侧的唯一持有处（docs/sockets/delivery.md）。
 *
 * 为什么这层要存在：Dart 的主引擎住在 `MainActivity` 里，划掉任务卡片、厂商强停、
 * 手机重启之后它都不在了。旧口径是"全局单闹钟，到点由 Dart 重锚续下一站"，于是
 * 应用一不在，下一站就没人挂。现在改成重锚时把能预排的站一次下发，这里存进
 * SharedPreferences 并逐站挂进 `AlarmManager`：进程在不在都不影响已经排上的站。
 *
 * 挂钟用 [AlarmManager.setAlarmClock]：它是"用户设的闹钟"，Doze 与国产 ROM 的
 * 省电策略不会把它推迟到亮屏，而且不吃 `SCHEDULE_EXACT_ALARM` 授权——OPPO 上那个
 * 开关默认常常是关的。代价是状态栏会多一个系统闹钟图标，正好让人看得见下一站。
 *
 * 站点表是快照：应用不在期间人改了任务，旧站仍会按原定时刻投递，下一次打开应用
 * 重锚即覆盖整表。这个代价登记在 architecture.md §11。
 */
object AlarmStationStore {

    private const val TAG = "gtd"
    private const val PREFS = "gtd_alarm_stations"
    private const val KEY_STATIONS = "stations"
    private const val KEY_RING_SECONDS = "ringSeconds"

    /** 站点对象里的键（与 MethodChannel 下发的字段同名）。 */
    private const val KEY_AT = "at"
    private const val KEY_FIRED = "fired"

    /** 过点超过这个宽限就不补投，与 Dart 侧 `pointReminderGrace` 同值。 */
    private const val GRACE_MILLIS = 30 * 60 * 1000L

    /** requestCode 基线：0 留给旧版单闹钟，别跟它撞。 */
    private const val REQUEST_BASE = 1

    /** 状态栏闹钟图标点开应用用的 PendingIntent id。 */
    private const val SHOW_REQUEST_CODE = 0x0F12

    // ------------------------------------------------------------------ 存盘

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun read(context: Context): JSONArray = try {
        JSONArray(prefs(context).getString(KEY_STATIONS, null) ?: "[]")
    } catch (_: Throwable) {
        JSONArray()
    }

    private fun write(context: Context, stations: JSONArray) {
        // 开机恢复与到点标记之后进程随时可能被回收，必须同步落盘。
        prefs(context).edit().putString(KEY_STATIONS, stations.toString()).commit()
    }

    private fun ringSeconds(context: Context): Int =
        prefs(context).getInt(KEY_RING_SECONDS, 60)

    private fun key(station: JSONObject): String =
        "${station.optString(ReminderExtras.TASK_ID)}@${station.optLong(KEY_AT)}"

    /** 从站点对象还原一条提醒：广播、全屏页、停铃按钮都认同一份 extras 形状。 */
    private fun reminderOf(station: JSONObject): Reminder {
        val ids = station.optJSONArray(ReminderExtras.ACTION_IDS)
        val labels = station.optJSONArray(ReminderExtras.ACTION_LABELS)
        val actions = ArrayList<ReminderAction>()
        if (ids != null) {
            for (i in 0 until ids.length()) {
                actions += ReminderAction(
                    ids.optString(i),
                    labels?.optString(i) ?: ids.optString(i),
                )
            }
        }
        return Reminder(
            taskId = station.optString(ReminderExtras.TASK_ID),
            title = station.optString(ReminderExtras.TITLE),
            body = station.optString(ReminderExtras.BODY).takeIf { it.isNotEmpty() },
            channel = ReminderChannel.fromName(station.optString(ReminderExtras.CHANNEL)),
            fullScreen = station.optBoolean(ReminderExtras.FULL_SCREEN),
            actions = actions,
        )
    }

    // ------------------------------------------------------------ 挂钟 / 取消

    /**
     * 用整张新表替换旧的：先照旧表取消所有闹钟，再写新表并逐站挂上。
     *
     * 站点在表里的**下标**就是 PendingIntent 的 requestCode，所以取消与恢复都能按
     * 同一套身份命中，不需要拿 taskId 去算 hash（会撞）。
     */
    fun replaceAndSchedule(context: Context, stations: JSONArray, seconds: Int): Boolean {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        cancelAll(app)
        prefs(app).edit()
            .putString(KEY_STATIONS, stations.toString())
            .putInt(KEY_RING_SECONDS, seconds)
            .commit()
        var armed = 0
        for (i in 0 until stations.length()) {
            val station = stations.optJSONObject(i) ?: continue
            if (station.optBoolean(KEY_FIRED)) continue
            if (arm(app, manager, i + REQUEST_BASE, station)) armed++
        }
        Log.i(TAG, "stations replaced: total=${stations.length()} armed=$armed")
        return true
    }

    /** 取消当前表里的所有闹钟（不清表：开机恢复还要用）。 */
    fun cancelAll(context: Context) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val stations = read(app)
        for (i in 0 until stations.length()) {
            val station = stations.optJSONObject(i) ?: continue
            val intent = stationIntent(app, station)
            // 与 arm() 用同一组 flags 构造，PendingIntent 身份必定命中——不用
            // FLAG_NO_CREATE，匹配不上就会漏取消一个还挂着的旧站。
            val pending = PendingIntent.getBroadcast(
                app,
                i + REQUEST_BASE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            try {
                manager.cancel(pending)
            } catch (t: Throwable) {
                Log.w(TAG, "cancel station failed: ${t.message}")
            }
        }
    }

    /**
     * 开机 / 应用更新后重挂：进程里没有 Dart，只能照盘上的表来。
     *
     * 已投过的站跳过；过点但在 30 分钟补响宽限内的推到下一秒立刻触发；过了宽限的
     * 直接标成已投，免得每次开机都补一遍陈年旧账。
     */
    fun restore(context: Context) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val stations = read(app)
        if (stations.length() == 0) {
            Log.i(TAG, "stations restore: empty table, nothing to do")
            return
        }
        val now = System.currentTimeMillis()
        var armed = 0
        var expired = 0
        for (i in 0 until stations.length()) {
            val station = stations.optJSONObject(i) ?: continue
            if (station.optBoolean(KEY_FIRED)) continue
            val at = station.optLong(KEY_AT)
            if (at < now - GRACE_MILLIS) {
                station.put(KEY_FIRED, true)
                expired++
                continue
            }
            val whenMillis = if (at <= now) now + 1_000L else at
            if (arm(app, manager, i + REQUEST_BASE, station, whenMillis)) armed++
        }
        write(app, stations)
        Log.i(TAG, "stations restore: armed=$armed expired=$expired")
    }

    /** 到点投过一次就记下，重启恢复时不再补投同一站。 */
    fun markFired(context: Context, stationKey: String?) {
        if (stationKey.isNullOrEmpty()) return
        val app = context.applicationContext
        val stations = read(app)
        for (i in 0 until stations.length()) {
            val station = stations.optJSONObject(i) ?: continue
            if (key(station) == stationKey) {
                station.put(KEY_FIRED, true)
                write(app, stations)
                return
            }
        }
    }

    /** 闹钟广播 Intent：站点自己的时刻与 key 一起带上，接收器才知道该记哪一格。 */
    private fun stationIntent(context: Context, station: JSONObject): Intent =
        alarmIntent(context, reminderOf(station), ringSeconds(context)).apply {
            putExtra(ReminderExtras.AT_MILLIS, station.optLong(KEY_AT))
            putExtra(ReminderExtras.STATION_KEY, key(station))
        }

    /** 挂一站。系统拒绝 `setAlarmClock` 时退回精确闹钟，再不行才用窗口化尽力而为。 */
    private fun arm(
        context: Context,
        manager: AlarmManager,
        requestCode: Int,
        station: JSONObject,
        whenMillis: Long = station.optLong(KEY_AT),
    ): Boolean {
        val pending = PendingIntent.getBroadcast(
            context,
            requestCode,
            stationIntent(context, station),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val show = PendingIntent.getActivity(
            context,
            SHOW_REQUEST_CODE,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return try {
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(whenMillis, show), pending)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "setAlarmClock rejected at=$whenMillis: ${t.message}")
            try {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()) {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMillis, pending)
                } else {
                    manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMillis, pending)
                }
                true
            } catch (t2: Throwable) {
                Log.w(TAG, "fallback alarm failed: ${t2.message}")
                false
            }
        }
    }
}
