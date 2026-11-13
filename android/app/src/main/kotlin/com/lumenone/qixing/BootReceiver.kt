package com.lumenone.qixing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 系统重启 / 应用更新后把手服务的恢复点。
 *
 * 开机时系统会清掉所有前台服务、悬浮窗口与 AlarmManager 闹钟。站点表由
 * [AlarmStationStore] 存在原生 prefs 里，这里照表重挂，不需要等 Dart 进程起来；
 * 标准档软提醒的下一站仍要重算，那条代价登记在 architecture.md §11。
 *
 * 把手只在用户此前明确开过（原生 prefs 的 `enabled` 标记）时才拉回来，没开过
 * 一概不碰——不因为一次重启凭空弹出一个悬浮窗。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> Unit
            else -> return
        }
        // 系统已经把闹钟全清了：先照站点表挂回来，这一步不依赖应用被打开。
        Log.i("gtd", "boot receiver: restoring alarm stations")
        AlarmStationStore.restore(context)
        if (!OverlayHandleService.isEnabled(context)) return
        Log.i("gtd", "boot receiver: restoring overlay handle")
        OverlayHandleService.restore(context)
    }
}
