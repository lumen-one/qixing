import 'package:flutter/material.dart';

import '../../application/daily_digest.dart';
import '../../application/delivery.dart';
import '../../domain/plan.dart';
import '../app_controller.dart';
import '../dialogs/snooze_sheet.dart';
import '../theme.dart';
import '../time_format.dart';

/// 提醒回流监听（§7.2）：NotificationPort 的 shown 流 / 前台轮询产出
/// ReminderEvent → 渲染提醒弹窗（桌面 = "托盘"即应用窗口；安卓 = 前台兜底）。
/// 系统通知/全屏闹钟的安卓适配器在设备阶段接入同一个插座。
///
/// 两种提醒长两样：任务是"该做这件事了"（完成 / 推迟），编排条目只有一句话
/// （没有按钮——能推迟的是任务，[panels/plan.md](../../docs/panels/plan.md)『到点提醒』）。
class ReminderListener extends StatefulWidget {
  final AppController controller;
  final Widget child;

  const ReminderListener({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<ReminderListener> createState() => _ReminderListenerState();
}

class _ReminderListenerState extends State<ReminderListener> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void didUpdateWidget(covariant ReminderListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final shown = widget.controller.lastReminder;
    if (shown == null || !mounted) return;
    widget.controller.clearReminder();
    final task = widget.controller.taskById(shown.event.taskId);
    if (task == null) {
      // 编排条目与每日收尾：查不到任务是对的（它们本来就不是任务），照草案弹。
      final draft = shown.draft;
      if (draft == null) return;
      if (isPlanReminderId(shown.event.taskId)) {
        _showPlanDialog(draft);
      } else if (isDailyDigestId(shown.event.taskId)) {
        _showDigestDialog(draft);
      }
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.alarm, color: AppColors.accent),
          const SizedBox(width: 8),
          const Text('该做这件事了'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 6),
            if (task.deadline != null)
              Text('截止 ${fmtDateTime(ctx, task.deadline!)}'),
            // '长期'任务没有剩余工时（D18）；?? 0 只是空值安全。
            if ((task.remainingWork ?? 0) > 0)
              Text('剩余约 ${task.remainingWork} 分钟'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              showModalBottomSheet<void>(
                context: ctx,
                builder: (_) =>
                    SnoozeSheet(controller: widget.controller, task: task),
              );
            },
            child: const Text('推迟…'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.controller.snooze(task.id, minutes: 60);
            },
            child: const Text('推迟 1 小时'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.controller.complete(task.id);
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /// 编排条目的提醒：只有标题与时刻，没有可以按的动作。
  void _showPlanDialog(ReminderDraft draft) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.event_note_outlined, color: AppColors.accent),
          const SizedBox(width: 8),
          const Text('到点了'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(draft.title, style: Theme.of(ctx).textTheme.titleMedium),
            if (draft.body != null) ...[
              const SizedBox(height: 6),
              Text(draft.body!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 每日收尾：报件数与几个标题，唯一的去处是今日清单（决定卡 2026-11-26）。
  void _showDigestDialog(ReminderDraft draft) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.checklist_outlined, color: AppColors.accent),
          const SizedBox(width: 8),
          const Text('收尾提醒'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(draft.title, style: Theme.of(ctx).textTheme.titleMedium),
            if (draft.body != null) ...[
              const SizedBox(height: 6),
              Text(draft.body!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.controller.openTodayFromNotification();
            },
            child: const Text('看今日清单'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
