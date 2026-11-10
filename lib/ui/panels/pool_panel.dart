import 'package:flutter/material.dart';

import '../../application/today_view.dart';
import '../../domain/task.dart';
import '../app_controller.dart';
import '../dialogs/routine_edit_dialog.dart';
import '../dialogs/task_detail_sheet.dart';
import '../theme.dart';
import '../widgets/task_actions.dart';
import '../widgets/task_selection.dart';
import '../widgets/task_tile.dart';

/// 任务池页（ui-interaction.md §6.3；页序见 `ui/panel_pages.dart`）。
/// 一条横线分两段：横线前 = 计划段（未来任务 + 周期规则条目），横线后 =
/// 散件段（三无）。**计划段按日期升序、不可拖**；**散件段可上下拖拽**，仅为整理
/// 位置（无调度含义），顺序记 metadata（`pool_order`）重启保留，新建散件进组末尾。
/// 空状态："池干水清"。
///
/// 周期条目（决议 27）：按下一次发生日期升序插入计划段对应位置，是否显示
/// 由设置『周期任务在任务池的显示』决定；条目本身只读，点它跳『编辑规则』。
///
/// 多选（§10#23）：[selection] 由面板持有（跨页保留），周期条目**不可勾选**
/// （它不是任务，动作只有"编辑规则"）。
///
/// 下拉搜索（[panels/pool.md](../../docs/panels/pool.md)『下拉搜索』）：列表在
/// 顶部继续下拉，页顶拉出一条搜索框（页内一条，**不是覆盖页**）。开合与行程在
/// 控制器（返回键要问它），关键字与焦点归这里。
class PoolPanel extends StatefulWidget {
  final AppController controller;
  final TaskSelection selection;

  const PoolPanel({
    super.key,
    required this.controller,
    required this.selection,
  });

  @override
  State<PoolPanel> createState() => _PoolPanelState();
}

class _PoolPanelState extends State<PoolPanel> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 上一帧搜索框开没开：只在"刚打开"那一刻把焦点交出去，不然每帧都抢一遍，
  /// 点 × 之后焦点会立刻被抢回来。
  bool _wasOpen = false;

  @override
  void initState() {
    super.initState();
    _wasOpen = widget.controller.poolSearchOpen;
    widget.controller.addListener(_onControllerChanged);
    // 面板收起前放焦点（与灵感页 / 速记同一套，见 [AppController.addPageTeardown]）。
    widget.controller.addPageTeardown(_releaseFocus);
  }

  @override
  void didUpdateWidget(covariant PoolPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.removePageTeardown(_releaseFocus);
      widget.controller.addListener(_onControllerChanged);
      widget.controller.addPageTeardown(_releaseFocus);
      _wasOpen = widget.controller.poolSearchOpen;
    }
  }

  @override
  void dispose() {
    widget.controller.removePageTeardown(_releaseFocus);
    widget.controller.removeListener(_onControllerChanged);
    _focus.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _releaseFocus() async => _focus.unfocus();

  void _onControllerChanged() {
    if (!mounted) return;
    final open = widget.controller.poolSearchOpen;
    if (open != _wasOpen) {
      _wasOpen = open;
      if (!open) {
        // 收起 = 清空：下次拉出来是一张白纸。面板收起不走这里（那只放焦点，
        // 关键字留着，回来接着看）。
        _focus.unfocus();
        _query.clear();
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.selection,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final raw = widget.controller.poolView;
    final searching = _query.text.trim().isNotEmpty;
    final view = filterPoolView(raw, _query.text);

    return Column(
      children: [
        _PoolSearchBar(
          controller: widget.controller,
          query: _query,
          focus: _focus,
          onChanged: () => setState(() {}),
          onClear: () {
            _query.clear();
            widget.controller.closePoolSearch();
            setState(() {});
          },
        ),
        Expanded(
          child: raw.isEmpty
              // 池子真空：不接手势（拉了也搜不出东西）。无排序档散件段搬去了
              // 今日页底部（v1.27），文案要说清它们在哪。
              ? _empty(theme, raw.hiddenLooseCount > 0)
              : NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: (searching && view.rows.isEmpty && view.loose.isEmpty)
                      ? _noMatch(theme)
                      : _list(context, theme, view, searching),
                ),
        ),
      ],
    );
  }

  /// 只认手指拖（`dragDetails != null`）：鼠标滚轮 / 触控板"滚到头继续滚"是常态，
  /// 认了就是天天误触。`depth != 0` 是散件段那个嵌套列表的通知，跳过。
  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    // 选择模式下不接：过滤会把勾过的件藏起来，一边搜一边勾是自找混乱。
    if (widget.selection.selecting) return false;
    if (n is OverscrollNotification && n.dragDetails != null) {
      // 顶部继续下拉时 overscroll 是负的（像素已经不能再减）。
      widget.controller.pullPoolSearch(-n.overscroll);
    } else if (n is ScrollEndNotification) {
      widget.controller
          .settlePoolSearch(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  Widget _list(
    BuildContext context,
    ThemeData theme,
    PoolView view,
    bool searching,
  ) =>
      ListView(
        // 内容不满一屏也要能拖出 overscroll：下拉出搜索框靠它。
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 96),
        children: [
          if (view.rows.isNotEmpty) ...[
            const _SectionLabel('计划段'),
            // **不可拖**：这一段按日期排（panels/pool.md），行尾也不摆拖把手。
            for (final row in view.rows) _row(context, theme, row),
          ],
          if (view.rows.isNotEmpty && view.loose.isNotEmpty)
            const _PoolDivider(),
          if (view.loose.isNotEmpty) ...[
            if (searching)
              // 搜索态不摆拖把手：过滤后的子集写 `pool_order` 会把没显示的件
              // 顺序打乱（[_persistOrder] 拿的是当前列表）。
              for (final task in view.loose)
                _looseTile(context, theme, task, null)
            else
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                // 新 API：`newIndex` 已按"移除旧位"调整好，直接就是落点（同挂起组与编排）。
                onReorderItem: (o, n) => _persistOrder(view.loose, o, n),
                children: [
                  for (var i = 0; i < view.loose.length; i++)
                    _looseTile(context, theme, view.loose[i], i),
                ],
              ),
          ],
        ],
      );

  Widget _looseTile(
    BuildContext context,
    ThemeData theme,
    Task task,
    int? index,
  ) =>
      TaskTile(
        key: ValueKey('loose-${task.id}'),
        controller: widget.controller,
        task: task,
        trail: TileTrail.date,
        highlight: task.id == widget.controller.focusedTaskId,
        selecting: widget.selection.selecting,
        selected: widget.selection.contains(task.id),
        onTap: _tap(context, task),
        onLongPress: _longPress(context, task),
        trailing: index == null ? null : _grip(index, theme),
      );

  Widget _empty(ThemeData theme, bool looseMoved) => Center(
        child: FadeIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                  looseMoved
                      ? Icons.today_outlined
                      : Icons.water_drop_outlined,
                  size: 44,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(looseMoved ? '散件都在今日清单底部' : '池干水清'),
            ],
          ),
        ),
      );

  Widget _noMatch(ThemeData theme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            const Text('没有匹配的条目'),
          ],
        ),
      );

  /// 计划段的一行：任务行与周期条目都只读——这一段按日期排，不给拖。
  Widget _row(BuildContext context, ThemeData theme, PoolRow row) {
    if (row is PoolRoutineRow) {
      final focused = widget.controller.settingsFocusRoutineId == row.routine.id;
      return Card(
        key: ValueKey('routine-${row.routine.id}-${row.at.millisecondsSinceEpoch}'),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        shape: focused
            ? RoundedRectangleBorder(
                side: BorderSide(color: AppColors.accent, width: 1.6),
                borderRadius: BorderRadius.circular(14),
              )
            : null,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.repeat, size: 18, color: AppColors.accent),
          title: Text(row.routine.title, maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${routineSubtitle(row.routine)} · ${_fmtDay(row.at)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Text('例行', style: TextStyle(fontSize: 11.5)),
          onTap: () => widget.controller.focusRoutineInSettings(row.routine.id),
        ),
      );
    }
    final task = (row as PoolTaskRow).task;
    return TaskTile(
      key: ValueKey('plan-${task.id}'),
      controller: widget.controller,
      task: task,
      trail: TileTrail.date,
      highlight: task.id == widget.controller.focusedTaskId,
      selecting: widget.selection.selecting,
      selected: widget.selection.contains(task.id),
      onTap: _tap(context, task),
      onLongPress: _longPress(context, task),
    );
  }

  /// 点条目：选择模式下是勾选，平时是详情卡（与今日页同款）。
  VoidCallback _tap(BuildContext context, Task task) => widget.selection.selecting
      ? () => widget.selection.toggle(task.id)
      : () => showTaskDetailSheet(context, task);

  VoidCallback? _longPress(BuildContext context, Task task) =>
      widget.selection.selecting
          ? null
          : () => showPoolMenu(context, widget.controller, task,
              onSelectMode: () => widget.selection.begin(task.id));

  /// 拖把手（只有散件段有）：选择模式下不渲染 = 那一段不可拖。
  Widget? _grip(int i, ThemeData theme) => widget.selection.selecting
      ? null
      : ReorderableDragStartListener(
          index: i,
          child: Icon(Icons.drag_handle,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
        );

  /// 拖拽整理 = 仅显示序（决议 14）：整段重编 pool_order，重启保留。
  ///
  /// **只有散件段走这里**（[setPoolOrders]）：计划段按日期排、不可拖，所以在池子里
  /// 整理位置这件事只剩"散件谁在前"这一件（[决定](../../docs/decisions/2026-10-31-pool-plan-date-order.md)）。
  ///
  /// 无排序模式下写的是同一个 `pool_order`（决议 43）：今日页 ⑥ 与池子散件段共用，
  /// 两处顺序一致；`manual_order` 是今日 ③ 的序号，与这里互不相干。
  Future<void> _persistOrder(
      List<Task> section, int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final ids = [for (final t in section) t.id]
      ..removeAt(oldIndex)
      ..insert(newIndex, section[oldIndex].id);
    await widget.controller.setPoolOrders(ids);
  }

  static String _fmtDay(DateTime d) =>
      '${d.month}-${d.day.toString().padLeft(2, '0')}'
      '${d.hour == 0 && d.minute == 0 ? '' : ' ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'}';
}

/// 页顶那条搜索框：高度由展开进度（0–1）决定，收起时整条不挂载。
///
/// 拖动跟手来自控制器的 `poolSearchPull`（每帧一个值，不重建面板）；松手补满 /
/// 弹回用本地 [AnimationController] 补完，比 [AnimatedContainer] 可控——后者
/// 拖动时每帧换目标会拖着走，收完也不会自己卸子树。
class _PoolSearchBar extends StatefulWidget {
  final AppController controller;
  final TextEditingController query;
  final FocusNode focus;
  final VoidCallback onChanged;
  final VoidCallback onClear;

  const _PoolSearchBar({
    required this.controller,
    required this.query,
    required this.focus,
    required this.onChanged,
    required this.onClear,
  });

  /// 一行输入框 + 上下留白。
  static const double height = 44;

  @override
  State<_PoolSearchBar> createState() => _PoolSearchBarState();
}

class _PoolSearchBarState extends State<_PoolSearchBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..value = widget.controller.poolSearchOpen ? 1 : 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.controller.poolSearchPull.addListener(_onPull);
    widget.controller.poolSearchDragging.addListener(_onDragging);
    // 展开动画落位时把焦点交给输入框：拉出来就能直接打字。放在"动画完成"这一刻，
    // 是因为第一帧的高度还不够一行，输入框还没挂载。
    _ctrl.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(covariant _PoolSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.poolSearchPull.removeListener(_onPull);
      oldWidget.controller.poolSearchDragging.removeListener(_onDragging);
      widget.controller.addListener(_onControllerChanged);
      widget.controller.poolSearchPull.addListener(_onPull);
      widget.controller.poolSearchDragging.addListener(_onDragging);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.poolSearchPull.removeListener(_onPull);
    widget.controller.poolSearchDragging.removeListener(_onDragging);
    _ctrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _settleTo(widget.controller.poolSearchOpen ? 1 : 0);
  }

  void _onDragging() {
    if (!widget.controller.poolSearchDragging.value) {
      _settleTo(widget.controller.poolSearchOpen ? 1 : 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed &&
        widget.controller.poolSearchOpen) {
      widget.focus.requestFocus();
    }
  }

  void _onPull() {
    if (!widget.controller.poolSearchDragging.value) return;
    // 跟手行程按 72dp 算满（与松手阈值同一个数）：拉满即开，拉一半弹回。
    _ctrl.value = (widget.controller.poolSearchPull.value /
            AppController.planPullThreshold)
        .clamp(0.0, 1.0);
  }

  void _settleTo(double value) {
    if (!mounted) return;
    _ctrl.animateTo(value,
        curve: value >= 1 ? Curves.easeOutCubic : Curves.easeInCubic);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final h = _ctrl.value * _PoolSearchBar.height;
          if (h < 1) return const SizedBox(width: double.infinity, height: 0);
          return SizedBox(
            height: h,
            // 跟手过程中高度不够一整行：裁掉下沿，别让输入框报溢出。
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: _PoolSearchBar.height,
                maxHeight: _PoolSearchBar.height,
                child: _bar(context),
              ),
            ),
          );
        },
      );

  Widget _bar(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _PoolSearchBar.height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 6),
        child: Row(
          children: [
            Icon(Icons.search,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: widget.query,
                focusNode: widget.focus,
                style: theme.textTheme.bodyMedium,
                textInputAction: TextInputAction.search,
                onChanged: (_) => widget.onChanged(),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  hintText: '搜索任务池',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
            // 常驻：空着时它也是唯一的"收起"出口（返回键另算）。
            IconButton(
              tooltip: widget.query.text.isEmpty ? '收起' : '清空并收起',
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              icon: const Icon(Icons.close),
              onPressed: widget.onClear,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
        child: Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );
}

class _PoolDivider extends StatelessWidget {
  const _PoolDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('散件',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      );
}
