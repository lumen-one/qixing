import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../../domain/trash.dart';
import '../app_controller.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_tile.dart';

/// 回收站覆盖页（[panels/trash.md](../../../docs/panels/trash.md)）：已完成页
/// 滚到顶再往下拉翻出来，与编排 / 速记同一套进出（整块盖住面板，不占页序）。
///
/// **只做两件事**：捞回与清理。清单按删除时刻倒序（最近删的在最上面），行尾一颗
/// 『恢复』，长按菜单给『恢复』与『彻底删除』，页头一颗『清空回收站』。
/// 这一页没有自己的数据——改动全落在任务目录的 `.gtd/.trash/` 里。
class TrashOverlay extends StatelessWidget {
  final AppController controller;
  final VoidCallback onClose;

  const TrashOverlay({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final entries = controller.trashEntries;
          return Column(
            children: [
              _header(context, entries.length),
              const Divider(height: 1),
              Expanded(
                // 桌面没有触屏：上滑退出只能靠按住鼠标拖出来（与编排 / 速记同一条）。
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: PointerDeviceKind.values.toSet(),
                  ),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: entries.isEmpty
                        ? _empty(theme, context)
                        : _list(context, entries),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- 头部 ----

  Widget _header(BuildContext context, int count) {
    final theme = Theme.of(context);
    final hint = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 6, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
          Text('回收站', style: theme.textTheme.titleSmall),
          const SizedBox(width: 8),
          if (count > 0)
            Text('$count 件',
                style: theme.textTheme.labelMedium?.copyWith(color: hint)),
          const Spacer(),
          IconButton(
            tooltip: '清空回收站',
            icon: const Icon(Icons.delete_sweep_outlined),
            // 空的时候灰着：清空没有对象，按钮不该看起来可点。
            onPressed: count == 0 ? null : () => _purgeAll(context, count),
          ),
        ],
      ),
    );
  }

  // ---- 清单 ----

  Widget _empty(ThemeData theme, BuildContext context) => ListView(
        // 空态也要可滚：滚到底再上滑是这一页唯一的收起手势，空着也得能退。
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 72),
          Column(
            children: [
              Icon(Icons.delete_outline,
                  size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              const Text('回收站是空的'),
              const SizedBox(height: 4),
              Text('删掉的任务会先落到这里',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      );

  Widget _list(BuildContext context, List<TrashEntry> entries) => ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 24),
        itemCount: entries.length,
        itemBuilder: (context, i) => _tile(context, entries[i]),
      );

  Widget _tile(BuildContext context, TrashEntry entry) {
    final theme = Theme.of(context);
    final task = entry.task;
    return TaskTile(
      controller: controller,
      task: task,
      dimmed: true,
      onTap: () => showTaskDetailSheet(context, task),
      onLongPress: () => showTaskMenu(context, controller, task,
          kind: TaskMenuKind.trash),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 删除日期（同一年只写月-日）：回收站里最要紧的是"这是哪天的"，
          // 跟标题抢的宽度有限，标题照旧省略号收尾。
          Text(fmtDay(entry.deletedAt),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              tooltip: '恢复',
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: Icon(Icons.restore, color: AppColors.accent),
              onPressed: () => _restore(context, task.title, task.id),
            ),
          ),
        ],
      ),
    );
  }

  /// 清单滚到底后继续上滑 = 退出（与编排页同一条规则的两端）。
  ///
  /// **按轴筛，不按 depth 筛**：这一页外面套了横向 PageView，通知冒上来时
  /// depth 已经不是 0。只认手指拖出来的 overscroll，鼠标滚轮不算。
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll > 0) {
      controller.pullTrashExit(n.overscroll);
    } else if (n is ScrollEndNotification) {
      // 向上快甩是 dy < 0（页面往上走）。
      controller.settleTrashExit(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  // ---- 动作 ----

  Future<void> _restore(BuildContext context, String title, String id) async {
    await controller.restoreTask(id);
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text('已恢复「$title」'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _purgeAll(BuildContext context, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站？'),
        content: Text('将真正删除这 $count 件，不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await controller.purgeTrash();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('回收站已清空')));
  }
}
