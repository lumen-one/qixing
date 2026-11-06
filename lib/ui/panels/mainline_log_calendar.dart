import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/mainline.dart';
import '../app_controller.dart';
import '../theme.dart';

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 主线『记录』页（ui-interaction.md §6.9；页细则见 `docs/panels/mainline.md`）。
///
/// - 上半区是**不滚动**的月历：格子只放日期数字、有内容的小点、每段一根细条，
///   细条上不写字；记录段互不重叠，所以同一周的细条横向不相交，一条轨道就够；
/// - 下半区**不依赖选中日**，进来就常驻列出与本月相交的全部记录段，每段一张卡
///   （完整正文 + 起止日期与天数）。点某一天只滚到覆盖它的卡并双向高亮，
///   点卡片才进改文字 / 删除的对话框；
/// - 月头那行年月是视图开关：点它把上半区换成这一年的十二行月记，再点切回日历。
///   月记不覆盖任何一天，所以它不进格子、也不进记录列表
///   （`docs/decisions/2026-10-25-mainline-month-note.md`）。
///
/// 手势全部走一个 [Listener] + 几何换算（行高 = 可用高/周数、列宽 = 宽/7）：
/// 日历放在不滚动的区域里，纵向拖动不会被外面的列表抢走——跨周拖选要的就是这条。
/// 横滑按区域分工：**日历里 = 拖选日期**（这里不能让给翻页），
/// **下半区（记录列表 / 空提示）= 翻页**（向右滑回行为链，见 [onSwipeBack]）。
/// 月记模式下没有日历可拖，整块列表都归翻页那条手势。
class MainlineLogCalendar extends StatefulWidget {
  final AppController controller;
  final Mainline mainline;
  final bool readOnly;

  /// 下半区向右滑 → 回行为链（覆盖页用 PageController 翻回去）。
  final VoidCallback? onSwipeBack;

  const MainlineLogCalendar({
    super.key,
    required this.controller,
    required this.mainline,
    this.readOnly = false,
    this.onSwipeBack,
  });

  @override
  State<MainlineLogCalendar> createState() => _MainlineLogCalendarState();
}

class _MainlineLogCalendarState extends State<MainlineLogCalendar> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _selected;

  /// 上半区是月历还是月记列表（点月头那行年月切换）。
  bool _monthView = false;

  DateTime? _dragAnchor;
  DateTime? _dragCursor;
  bool _dragging = false;
  Offset? _downAt;

  @override
  void didUpdateWidget(covariant MainlineLogCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一条主线（归档后看另一条）：选中日与拖动态归零
    if (oldWidget.mainline.id != widget.mainline.id) {
      _selected = null;
      _dragAnchor = null;
      _dragCursor = null;
      _dragging = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _monthHeader(theme),
        if (_monthView)
          // 月记没有日历可拖，整块列表让给"右滑回行为链"那条手势。
          Expanded(child: _swipeBackLayer(_buildMonthList(theme)))
        else ...[
          const SizedBox(height: 2),
          _weekdayRow(theme),
          Expanded(
            flex: 2,
            child: LayoutBuilder(builder: (context, box) {
              final layout = _Layout.of(
                  _month, box.maxWidth, box.maxHeight, widget.mainline);
              return _buildGrid(context, theme, layout, box);
            }),
          ),
          const Divider(height: 1),
          Expanded(flex: 3, child: _swipeBackLayer(_buildLogList(theme))),
        ],
      ],
    );
  }

  // ---------- 月头 ----------

  double _detailDx = 0;

  /// 下半区（记录列表 / 空提示）向右滑 = 回行为链。
  ///
  /// 日历那块必须留给"拖选日期"，翻页手势只能落在这一半；横向拖动与里面
  /// SingleChildScrollView 的纵向滚动正交，两边不抢手。
  Widget _swipeBackLayer(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _detailDx = 0,
      onHorizontalDragUpdate: (d) => _detailDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_detailDx > 48 || v > 500) widget.onSwipeBack?.call();
        _detailDx = 0;
      },
      child: child,
    );
  }

  Widget _monthHeader(ThemeData theme) {
    return Row(
      children: [
        _chevron(Icons.chevron_left, () => _step(-1)),
        Expanded(
          child: Center(
            // 这行年月就是视图开关：点它把上半区在月历与月记之间切。
            child: Tooltip(
              message: _monthView ? '回月历' : '按月记',
              child: InkWell(
                onTap: () => setState(() => _monthView = !_monthView),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 240dp 的窄面板上左右两个箭头 + 这行字本来就贴边，留个省略兜底
                      // （真机上不会触发，测试字体是等宽方块才会）。
                      Flexible(
                        child: Text(
                          _monthView
                              ? '${_month.year} 年'
                              : '${_month.year} 年 ${_month.month} 月',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.swap_horiz,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        _chevron(Icons.chevron_right, () => _step(1)),
      ],
    );
  }

  /// 翻一格：月历翻月，月记翻年（月记列表是一年十二行）。
  void _step(int delta) {
    setState(() {
      _month = _monthView
          ? DateTime(_month.year + delta, _month.month)
          : DateTime(_month.year, _month.month + delta);
      _selected = null;
    });
  }

  Widget _chevron(IconData icon, VoidCallback onTap) => SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: Icon(icon),
          onPressed: onTap,
        ),
      );

  Widget _weekdayRow(ThemeData theme) => Row(
        children: [
          for (final w in _weekLabels)
            Expanded(
              child: Center(
                child: Text(w,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
        ],
      );

  // ---------- 网格 ----------

  Widget _buildGrid(
    BuildContext context,
    ThemeData theme,
    _Layout layout,
    BoxConstraints box,
  ) {
    final cellW = box.maxWidth / 7;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _downAt = e.localPosition;
        _dragAnchor = layout.dayAt(e.localPosition);
        _dragCursor = _dragAnchor;
        _dragging = false;
      },
      onPointerMove: (e) {
        final anchor = _dragAnchor;
        if (anchor == null) return;
        final at = layout.dayAt(e.localPosition);
        if (at == null) return;
        final down = _downAt;
        if (!_dragging &&
            down != null &&
            (e.localPosition - down).distance > 6) {
          _dragging = true;
        }
        if (_dragging) setState(() => _dragCursor = at);
      },
      onPointerUp: (e) {
        final anchor = _dragAnchor;
        final cursor = _dragCursor;
        final moved = _dragging;
        _dragAnchor = null;
        _dragCursor = null;
        _dragging = false;
        if (anchor == null) return;
        if (moved && cursor != null) {
          final start = anchor.isBefore(cursor) ? anchor : cursor;
          final end = anchor.isBefore(cursor) ? cursor : anchor;
          setState(() {});
          _promptNewLog(start: start, end: end);
          return;
        }
        // 没拖 = 点：只选中那天（滚到覆盖它的卡片并高亮），文字本来就在下面。
        final day = layout.dayAt(e.localPosition);
        if (day != null) _selectDay(day);
      },
      onPointerCancel: (_) {
        _dragAnchor = null;
        _dragCursor = null;
        _dragging = false;
      },
      child: SizedBox(
        width: box.maxWidth,
        height: box.maxHeight,
        child: Stack(
          children: [
            for (var w = 0; w < layout.weeks.length; w++)
              Positioned(
                top: layout.weekTop(w),
                left: 0,
                right: 0,
                height: layout.rowH,
                child: _weekStack(context, theme, layout, w, cellW),
              ),
          ],
        ),
      ),
    );
  }

  Widget _weekStack(
    BuildContext context,
    ThemeData theme,
    _Layout layout,
    int weekIndex,
    double cellW,
  ) {
    final week = layout.weeks[weekIndex];
    final children = <Widget>[];

    // 拖选中的临时高亮（铺在日期数字底下）
    if (_dragging) {
      final a = _dragAnchor;
      final b = _dragCursor;
      if (a != null && b != null) {
        final start = a.isBefore(b) ? a : b;
        final end = a.isBefore(b) ? b : a;
        final seg = layout.segmentOf(start, end, weekIndex);
        if (seg != null) {
          children.add(Positioned(
            left: seg.$1 * cellW + 2,
            width: (seg.$2 - seg.$1 + 1) * cellW - 4,
            top: 2,
            height: layout.dateH - 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ));
        }
      }
    }

    // 日期数字 + 内容小点
    for (var col = 0; col < 7; col++) {
      final day = week.cells[col];
      if (day == null) continue;
      final isToday = isSameDay(day, DateTime.now());
      final selected = _selected != null && isSameDay(day, _selected!);
      final marked = widget.mainline.hasActivityOn(day);
      children.add(Positioned(
        left: col * cellW,
        width: cellW,
        top: 0,
        height: layout.dateH,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? AppColors.accent
                  : isToday
                      ? AppColors.accent.withValues(alpha: 0.16)
                      : null,
            ),
            child: Text(
              '${day.day}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                fontWeight: isToday || selected ? FontWeight.w700 : null,
                color: selected ? theme.colorScheme.onPrimary : null,
              ),
            ),
          ),
        ),
      ));
      if (marked) {
        children.add(Positioned(
          left: col * cellW + cellW / 2 - 1.5,
          top: layout.dateH - 5,
          width: 3,
          height: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withValues(alpha: 0.85),
            ),
          ),
        ));
      }
    }

    // 每段记录一根细条：不写字、不叠放。段互不重叠，所以同一周里横向也不相交。
    for (final band in week.bands) {
      final highlighted = _selected != null && band.log.covers(_selected!);
      children.add(Positioned(
        left: band.startCol * cellW + 2,
        width: math.max((band.endCol - band.startCol + 1) * cellW - 4, 4),
        top: layout.dateH + 1,
        height: 4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: highlighted ? 1.0 : 0.5),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ));
    }

    return Stack(children: children);
  }

  /// 点某一天：只把覆盖它的那张卡滚到可见并高亮，不负责让文字出现。
  void _selectDay(DateTime day) {
    setState(() => _selected = day);
    final index = _visibleLogs().indexWhere((l) => l.covers(day));
    if (index < 0) return;
    final key = GlobalObjectKey('log-card-$index');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: 0.15,
      );
    });
  }

  // ---------- 月记 ----------

  /// 月记：一年十二行，一个月一句。写过的行左侧有圆点，没写的是灰字提示。
  Widget _buildMonthList(ThemeData theme) {
    final year = _month.year;
    return ListView(
      // 不满一屏也要能 overscroll：覆盖页的上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 14),
      children: [
        for (var m = 1; m <= 12; m++) _monthRow(theme, year, m),
        const SizedBox(height: 10),
        Text(
          '点某个月写一句，一个月只留一条；再点上面的年份回月历',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _monthRow(ThemeData theme, int year, int month) {
    final text = widget.mainline.monthNoteOf(year, month)?.text ?? '';
    final written = text.isNotEmpty;
    final now = DateTime.now();
    final isNow = year == now.year && month == now.month;
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: widget.readOnly ? null : () => _promptMonthNote(year, month),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(
          children: [
            // 写过的行左侧留一个点：与日历格子上那个点是同一个意思。
            SizedBox(
              width: 12,
              child: written
                  ? Center(
                      child: SizedBox(
                        width: 5,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.accent.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$month 月',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: isNow || written ? FontWeight.w600 : null,
                  color: isNow ? AppColors.accent : null,
                ),
              ),
            ),
            Expanded(
              child: Text(
                written ? text : (widget.readOnly ? '—' : '记一句'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: written ? theme.colorScheme.onSurface : muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 记录列表（常驻，不依赖选中日） ----------

  /// 与本月相交的记录段（跨月段在相邻两个月都看得到）。
  List<MainlineLog> _visibleLogs() {
    final monthStart = DateTime(_month.year, _month.month, 1);
    final monthEnd = DateTime(_month.year, _month.month + 1, 0);
    return [
      for (final l in widget.mainline.logsInOrder)
        if (!l.end.isBefore(monthStart) && !l.start.isAfter(monthEnd)) l,
    ];
  }

  Widget _buildLogList(ThemeData theme) {
    final logs = _visibleLogs();
    final steps = _selected == null
        ? <MainlineStep>[]
        : widget.mainline.stepsDoneOn(_selected!);
    return SingleChildScrollView(
      // 不满一屏也要能 overscroll：覆盖页的上滑退出发生在"末尾之后"。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('本月记录 · ${logs.length} 段',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          if (steps.isNotEmpty && _selected != null)
            _daySteps(theme, _selected!, steps),
          if (logs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '按住日历拖选一段日期写记录；向右滑回行为链',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          for (var i = 0; i < logs.length; i++) _logCard(theme, logs[i], i),
        ],
      ),
    );
  }

  /// 选中日勾过步骤时补在列表顶部：自动流水是人勾出来的那一半，与手写的记录段分开。
  Widget _daySteps(ThemeData theme, DateTime day, List<MainlineStep> steps) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${day.month} 月 ${day.day} 日',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 3),
          for (final s in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle,
                      size: 14, color: AppColors.accent.withValues(alpha: 0.8)),
                  const SizedBox(width: 6),
                  if (s.doneAt != null) ...[
                    Text(_timeText(s.doneAt!),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      s.note.trim().isEmpty ? s.title : '${s.title} · ${s.note}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _logCard(ThemeData theme, MainlineLog log, int index) {
    final highlighted = _selected != null && log.covers(_selected!);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      // 下标做 key：手工写出两条完全相同的段也不会撞 GlobalKey。
      key: GlobalObjectKey('log-card-$index'),
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: widget.readOnly ? null : () => _promptEditLog(log),
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            color: highlighted
                ? AppColors.accent.withValues(alpha: 0.14)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.55),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 3,
                    color: AppColors.accent
                        .withValues(alpha: highlighted ? 1.0 : 0.5),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            log.text.trim().isEmpty
                                ? '（这段还没写字）'
                                : log.text.trim(),
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 3),
                          Text(_cardRangeText(log),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: muted)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _cardRangeText(MainlineLog l) {
    final a = '${l.start.month} 月 ${l.start.day} 日';
    if (l.dayCount == 1) return a;
    return '$a – ${l.end.month} 月 ${l.end.day} 日 · ${l.dayCount} 天';
  }

  static String _timeText(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  // ---------- 写记录 ----------

  Future<void> _promptNewLog({
    required DateTime start,
    required DateTime end,
  }) async {
    if (widget.readOnly) return;
    final outcome = await _textDialog(
      title: '这一段记点什么',
      subtitle: _rangeText(start, end),
      initial: '',
    );
    if (outcome == null) return;
    try {
      await widget.controller.addMainlineLog(
        widget.mainline.id,
        start: start,
        end: end,
        text: outcome.text,
      );
    } on StateError catch (e) {
      _toast(_errorText(e));
    }
  }

  Future<void> _promptEditLog(MainlineLog log) async {
    if (widget.readOnly) return;
    final outcome = await _textDialog(
      title: '改这一段',
      subtitle: _rangeText(log.start, log.end),
      initial: log.text,
      allowDelete: true,
    );
    if (outcome == null) return;
    // 身份取"打开对话框那一刻"的样子：这期间别处把它改了或删了，命令就找不到它、
    // 明确报错——而不是按下标改到另一条上。
    final ref = MainlineLogRef.of(log);
    try {
      if (outcome.deleted) {
        await widget.controller.removeMainlineLog(widget.mainline.id, ref);
        return;
      }
      await widget.controller
          .updateMainlineLog(widget.mainline.id, ref, text: outcome.text);
    } on StateError catch (e) {
      _toast(_errorText(e));
    }
  }

  /// 服务抛的 StateError 消息本身就是给用户看的中文，去掉 "Bad state: " 前缀即可。
  static String _errorText(Object e) {
    final s = e.toString();
    const prefix = 'Bad state: ';
    return s.startsWith(prefix) ? s.substring(prefix.length) : s;
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 写 / 改某个月的月记：一个月只留一条，有字才给删除。
  Future<void> _promptMonthNote(int year, int month) async {
    if (widget.readOnly) return;
    final existing = widget.mainline.monthNoteOf(year, month)?.text ?? '';
    final outcome = await _textDialog(
      title: '$year 年 $month 月',
      subtitle: '一个月写一句：这个月在做什么',
      initial: existing,
      allowDelete: existing.isNotEmpty,
      // 不写例句：上面那行 subtitle 已经说明这个框里写什么，框里再来一行灰字是同一句
      // 话的第二次，还占掉一行高。
      hint: null,
      minLines: 1,
    );
    if (outcome == null) return;
    await widget.controller.setMainlineMonthNote(
      widget.mainline.id,
      year,
      month,
      outcome.deleted ? '' : outcome.text,
    );
  }

  Future<_LogOutcome?> _textDialog({
    required String title,
    required String subtitle,
    required String initial,
    bool allowDelete = false,
    String? hint = '这段时间在做什么',
    int minLines = 2,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<_LogOutcome>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: minLines,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (allowDelete)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(const _LogOutcome(deleted: true)),
              child: const Text('删除'),
            ),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_LogOutcome(text: ctrl.text.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  }

  static String _rangeText(DateTime a, DateTime b) => isSameDay(a, b)
      ? '${a.year} 年 ${a.month} 月 ${a.day} 日'
      : '${a.year} 年 ${a.month} 月 ${a.day} 日 ~ '
          '${b.month} 月 ${b.day} 日（${b.difference(a).inDays + 1} 天）';
}

class _LogOutcome {
  final String text;
  final bool deleted;

  const _LogOutcome({this.text = '', this.deleted = false});
}

// ---------- 几何 ----------

/// 一次布局算好的几何：周行、行高、每周的细条段。手势换算全靠它。
class _Layout {
  final List<_Week> weeks;
  final double rowH;
  final double dateH;
  final double cellW;

  const _Layout({
    required this.weeks,
    required this.rowH,
    required this.dateH,
    required this.cellW,
  });

  double weekTop(int index) => index * rowH;

  static _Layout of(
    DateTime month,
    double width,
    double height,
    Mainline mainline,
  ) {
    final first = DateTime(month.year, month.month, 1);
    final lead = (first.weekday + 6) % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final weekCount = ((lead + daysInMonth) + 6) ~/ 7;
    final rowH = height <= 0 ? 44.0 : height / weekCount;
    // 细条固定 4dp，压在日期数字下面；不写字，所以不必给文字留余量。
    final dateH = math.min(30.0, math.max(rowH - 7, 20.0));

    final weeks = <_Week>[];
    final logs = mainline.logsInOrder;
    for (var w = 0; w < weekCount; w++) {
      final cells = <DateTime?>[];
      for (var col = 0; col < 7; col++) {
        final dayNum = w * 7 + col - lead + 1;
        cells.add(dayNum >= 1 && dayNum <= daysInMonth
            ? DateTime(month.year, month.month, dayNum)
            : null);
      }
      final weekStart = DateTime(month.year, month.month, 1 + w * 7 - lead);
      final weekEnd = weekStart.add(const Duration(days: 6));
      final bands = <_BandSegment>[];
      // 段只存对象引用，不存下标：命令通道按"起止日 + 原文"定位（见 MainlineLogRef）。
      for (final log in logs) {
        if (log.end.isBefore(weekStart) || log.start.isAfter(weekEnd)) continue;
        final startCol =
            math.max(0, log.start.difference(weekStart).inDays);
        final endCol = math.min(6, log.end.difference(weekStart).inDays);
        if (startCol > endCol) continue;
        bands.add(_BandSegment(
          log: log,
          startCol: startCol,
          endCol: endCol,
        ));
      }
      weeks.add(_Week(cells: cells, weekStart: weekStart, bands: bands));
    }

    return _Layout(
      weeks: weeks,
      rowH: rowH,
      dateH: dateH,
      cellW: width / 7,
    );
  }

  DateTime? dayAt(Offset local) {
    if (local.dx < 0 || local.dy < 0 || rowH <= 0 || cellW <= 0) return null;
    final week = (local.dy / rowH).floor();
    final col = (local.dx / cellW).floor();
    if (week < 0 || week >= weeks.length || col < 0 || col > 6) return null;
    return weeks[week].cells[col];
  }

  /// 一段日期落在这一周的哪几列；不与本周相交 → null。
  (int, int)? segmentOf(DateTime start, DateTime end, int weekIndex) {
    final week = weeks[weekIndex];
    final weekEnd = week.weekStart.add(const Duration(days: 6));
    if (end.isBefore(week.weekStart) || start.isAfter(weekEnd)) return null;
    final a = math.max(0, start.difference(week.weekStart).inDays);
    final b = math.min(6, end.difference(week.weekStart).inDays);
    if (a > b) return null;
    return (a, b);
  }
}

class _Week {
  final List<DateTime?> cells;
  final DateTime weekStart;
  final List<_BandSegment> bands;

  const _Week({
    required this.cells,
    required this.weekStart,
    required this.bands,
  });
}

class _BandSegment {
  final MainlineLog log;
  final int startCol;
  final int endCol;

  const _BandSegment({
    required this.log,
    required this.startCol,
    required this.endCol,
  });
}
