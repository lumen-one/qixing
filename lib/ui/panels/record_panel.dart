import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/logbook.dart';
import '../app_controller.dart';
import '../theme.dart';

const List<String> _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 记录页（`docs/panels/record.md` §6.15）：主线覆盖页的第 2 页，**与主线无关**。
///
/// - 数据只来自 `controller.logBook`（`记录.md`）：没有主线也照写，归档一条主线不改
///   这里一行，所以这一页**没有只读态**；
/// - 上半区是**不滚动的月历**：格子只放日期数字和每段一条**色带**（压在数字后面；
///   跨周那一侧不留圆角、贴到格子边），色带上不写字；记录段互不重叠，所以同一周的
///   色带横向不相交，一条轨道就够；
/// - 色带按段序取主题的四色轮，相邻段必然不同色；下半区记录卡左侧那条竖线用同一个
///   颜色（`docs/decisions/2026-11-07-mainline-record-decoupled.md`）；
/// - **勾选步骤不在这一页留痕**：没有小点、没有当天流水，这一页只记人写下的东西；
/// - 下半区**不依赖选中日**，进来就常驻列出与本月相交的全部记录段，每段一张卡
///   （完整正文 + 起止日期与天数）。点某一天只滚到覆盖它的卡并双向高亮，
///   点卡片才进改文字 / 删除的对话框；
/// - **改日期靠重圈**：对话框里日期那行右端一颗入口，点了收起对话框、日历上方冒一行
///   『拖选新的日期范围』，重新拖一次就回到对话框（文字保住）。日历格子自己不接
///   "拖动改期"——格子上拖一下到底是新建还是改，猜不出来；
/// - 月头那行年月是视图开关：点它把上半区换成这一年的十二行月记，再点切回日历。
///   月记不覆盖任何一天，所以它不进格子、也不进记录列表
///   （`docs/decisions/2026-10-25-mainline-month-note.md`）。
///
/// 手势全部走一个 [Listener] + 几何换算（行高 = 可用高/周数、列宽 = 宽/7）：
/// 日历放在不滚动的区域里，纵向拖动不会被外面的列表抢走——跨周拖选要的就是这条。
/// 横滑按区域分工：**日历里 = 拖选日期**（这里不能让给翻页），
/// **下半区（记录列表 / 空提示）= 翻页**（向右滑回行为链，见 [onSwipeBack]）。
/// 月记模式下没有日历可拖，整块列表都归翻页那条手势。
class RecordPanel extends StatefulWidget {
  final AppController controller;

  /// 下半区向右滑 → 回第 1 页（覆盖页用 PageController 翻回去）。
  final VoidCallback? onSwipeBack;

  const RecordPanel({
    super.key,
    required this.controller,
    this.onSwipeBack,
  });

  @override
  State<RecordPanel> createState() => _RecordPanelState();
}

class _RecordPanelState extends State<RecordPanel> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _selected;

  /// 上半区是月历还是月记列表（点月头那行年月切换）。
  bool _monthView = false;

  DateTime? _dragAnchor;
  DateTime? _dragCursor;
  bool _dragging = false;
  Offset? _downAt;

  /// 重圈模式：非空时，日历上的下一次**拖动或点按**是给这一段换日期，不是新建。
  ///
  /// 用 Completer 把"等用户圈完"这件事挂在页面上：对话框已经收起，圈完（或取消）
  /// 才把它叫醒。同一时刻只允许一个。
  Completer<(DateTime, DateTime)?>? _rangePick;

  /// 整本记录册里的记录段（按起始日升序）；这一页只读它。
  List<LogSegment> get _segments => widget.controller.logBook.segmentsInOrder;

  @override
  void dispose() {
    // 页面先走、圈还挂着：把等待叫醒，否则对话框那条线永远等着。
    final pending = _rangePick;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _monthHeader(theme),
        if (_rangePick != null) _rangePickBanner(theme),
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
                _month,
                box.maxWidth,
                box.maxHeight,
                _segments,
                _palette(theme),
              );
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
                // 重圈时不能换成月记列表：那半边没有格子可拖，人就被困在横幅里了。
                onTap: _rangePick != null
                    ? null
                    : () => setState(() => _monthView = !_monthView),
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

  // ---------- 重圈（改日期） ----------

  /// 等着"在日历上重新拖一次"的那一行。横幅本身就是当前模式的全部提示：
  /// 日历照旧画着色带，拖选高亮照旧跟手，用户不用学第二套手势。
  Widget _rangePickBanner(ThemeData theme) {
    final accent = AppColors.accent;
    return Container(
      height: 28,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined, size: 14, color: accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '拖选新的日期范围',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: accent),
            ),
          ),
          TextButton(
            onPressed: _cancelRangePick,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 挂起一次重圈：返回 (新起, 新止)，点『取消』就是 null。
  ///
  /// 返回的 future 一定等到横幅收起来之后才完成（`whenComplete` 排在前面），
  /// 所以调用方拿到结果时页面已经回到平常的样子。
  Future<(DateTime, DateTime)?> _pickRange() {
    final running = _rangePick;
    if (running != null) return running.future;
    final pending = Completer<(DateTime, DateTime)?>();
    setState(() {
      _rangePick = pending;
      // 月记列表上没有格子可拖：从那里点进来的先切回月历。
      _monthView = false;
      _selected = null;
    });
    return pending.future.whenComplete(() {
      if (!mounted) return;
      setState(() => _rangePick = null);
    });
  }

  void _completeRangePick(DateTime a, DateTime b) {
    final pending = _rangePick;
    if (pending == null || pending.isCompleted) return;
    pending.complete(a.isBefore(b) ? (a, b) : (b, a));
  }

  void _cancelRangePick() {
    final pending = _rangePick;
    if (pending == null || pending.isCompleted) return;
    pending.complete(null);
  }

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
          if (_rangePick != null) {
            _completeRangePick(start, end);
            return;
          }
          _promptNewLog(start: start, end: end);
          return;
        }
        // 没拖 = 点：重圈时"这一天"就是新范围（一天也算一段），平常只选中那天
        // （滚到覆盖它的卡片并高亮），文字本来就在下面。
        final day = layout.dayAt(e.localPosition);
        if (day == null) return;
        if (_rangePick != null) {
          _completeRangePick(day, day);
          return;
        }
        _selectDay(day);
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

    // 每段记录一条色带，压在日期数字后面：不写字、不叠放。段互不重叠，所以同一周里
    // 横向也不相交。跨周的那一侧不留圆角、贴到格子边，下一行从边起笔，读起来是连着的。
    final brightness = theme.brightness;
    for (final band in week.bands) {
      final highlighted = _selected != null && band.segment.covers(_selected!);
      final alpha = highlighted
          ? MainlineBandColors.bandAlphaSelected(brightness)
          : MainlineBandColors.bandAlpha(brightness);
      children.add(Positioned(
        left: band.startCol * cellW + (band.continuesLeft ? 0 : 2),
        width: math.max(
          (band.endCol - band.startCol + 1) * cellW -
              (band.continuesLeft ? 0 : 2) -
              (band.continuesRight ? 0 : 2),
          4,
        ),
        top: (layout.dateH - layout.barH) / 2,
        height: layout.barH,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: band.color.withValues(alpha: alpha),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(band.continuesLeft ? 0 : 999),
              right: Radius.circular(band.continuesRight ? 0 : 999),
            ),
          ),
        ),
      ));
    }

    // 拖选中的临时高亮：铺在色带之上、数字之下，压着已有段也看得见框到哪几天。
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

    // 日期数字
    for (var col = 0; col < 7; col++) {
      final day = week.cells[col];
      if (day == null) continue;
      final isToday = isSameDay(day, DateTime.now());
      final selected = _selected != null && isSameDay(day, _selected!);
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
    final text = widget.controller.logBook.monthNoteOf(year, month)?.text ?? '';
    final written = text.isNotEmpty;
    final now = DateTime.now();
    final isNow = year == now.year && month == now.month;
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: () => _promptMonthNote(year, month),
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
                written ? text : '记一句',
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
  List<LogSegment> _visibleLogs() {
    final monthStart = DateTime(_month.year, _month.month, 1);
    final monthEnd = DateTime(_month.year, _month.month + 1, 0);
    return [
      for (final l in _segments)
        if (!l.end.isBefore(monthStart) && !l.start.isAfter(monthEnd)) l,
    ];
  }

  Widget _buildLogList(ThemeData theme) {
    final logs = _visibleLogs();
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
          if (logs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '按住日历拖选一段日期写记录；向右滑回主线',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          for (var i = 0; i < logs.length; i++) _logCard(theme, logs[i], i),
        ],
      ),
    );
  }

  /// 四色轮（跟主题预设、明暗走）：日历上的色带与记录卡的竖线共用它。
  List<Color> _palette(ThemeData theme) =>
      AppColors.preset.bandsFor(theme.brightness);

  /// 这一段在四色轮里的位置：按起始日顺序，与日历上那条色带同一个下标。
  Color _colorOf(ThemeData theme, LogSegment segment) {
    final palette = _palette(theme);
    final i = _segments.indexWhere((s) => identical(s, segment));
    return palette[(i < 0 ? 0 : i) % palette.length];
  }

  Widget _logCard(ThemeData theme, LogSegment log, int index) {
    final highlighted = _selected != null && log.covers(_selected!);
    final muted = theme.colorScheme.onSurfaceVariant;
    final color = _colorOf(theme, log);
    return Padding(
      // 下标做 key：手工写出两条完全相同的段也不会撞 GlobalKey。
      key: GlobalObjectKey('log-card-$index'),
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        // 重圈时下面这摞卡不接点击：这时候点开另一段，两个对话框会抢同一圈日期。
        onTap: _rangePick != null ? null : () => _promptEditLog(log),
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            color: highlighted
                ? color.withValues(alpha: 0.14)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.55),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 3,
                    color: color.withValues(alpha: highlighted ? 1.0 : 0.55),
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

  static String _cardRangeText(LogSegment l) {
    final a = '${l.start.month} 月 ${l.start.day} 日';
    if (l.dayCount == 1) return a;
    return '$a – ${l.end.month} 月 ${l.end.day} 日 · ${l.dayCount} 天';
  }

  // ---------- 写记录 ----------

  Future<void> _promptNewLog({
    required DateTime start,
    required DateTime end,
  }) async {
    await _textDialog(
      title: '这一段记点什么',
      initial: '',
      start: start,
      end: end,
      onSave: (text) async {
        try {
          await widget.controller.addLog(start: start, end: end, text: text);
          return null;
        } on StateError catch (e) {
          return _errorText(e);
        }
      },
    );
  }

  /// 改一段：文字、日期都在同一张框里改。
  ///
  /// 『改日期』走重圈：对话框先收起，日历上重新拖一次再回来。一轮没弄好（撞了
  /// 别的段、或者又想换一天）就接着来；`ref` 始终是**打开那一刻**的身份——这期间
  /// 别处把它改了或删了，命令会找不到它并明确报错，而不是按下标改到另一条上。
  Future<void> _promptEditLog(LogSegment log) async {
    final ref = LogSegmentRef.of(log);
    var start = log.start;
    var end = log.end;
    var text = log.text;

    while (true) {
      // 每一轮都是一张新框：这一轮的闭包要钉住这一轮的日期。
      final from = start;
      final to = end;
      final outcome = await _textDialog(
        title: '改这一段',
        initial: text,
        start: from,
        end: to,
        pickRange: true,
        onSave: (t) async {
          try {
            await widget.controller
                .updateLog(ref, start: from, end: to, text: t);
            return null;
          } on StateError catch (e) {
            return _errorText(e);
          }
        },
        onDelete: () async {
          await widget.controller.removeLog(ref);
          return null;
        },
      );
      if (outcome == null || !outcome.wantsRange) return;

      // 收起框的时候里面可能有还没存的字：带去重圈，圈完原样回到框里。
      text = outcome.draftText!;
      final range = await _pickRange();
      if (!mounted) return;
      if (range == null) continue; // 横幅上点了取消：回对话框，日期不动
      start = range.$1;
      end = range.$2;
    }
  }

  /// 服务抛的 StateError 消息本身就是给用户看的中文，去掉 "Bad state: " 前缀即可。
  static String _errorText(Object e) {
    final s = e.toString();
    const prefix = 'Bad state: ';
    return s.startsWith(prefix) ? s.substring(prefix.length) : s;
  }

  /// 写 / 改某个月的月记：一个月只留一条，有字才给删除。
  Future<void> _promptMonthNote(int year, int month) async {
    final existing =
        widget.controller.logBook.monthNoteOf(year, month)?.text ?? '';
    await _textDialog(
      title: '$year 年 $month 月',
      subtitle: '一个月写一句：这个月在做什么',
      initial: existing,
      onSave: (text) async {
        await widget.controller.setMonthNote(year, month, text);
        return null;
      },
      onDelete: existing.isEmpty
          ? null
          : () async {
              await widget.controller.setMonthNote(year, month, '');
              return null;
            },
      // 不写例句：上面那行 subtitle 已经说明这个框里写什么，框里再来一行灰字是同一句
      // 话的第二次，还占掉一行高。
      hint: null,
      minLines: 1,
    );
  }

  /// 记录段 / 月记共用的那张输入框。
  ///
  /// **保存由对话框自己执行**：`onSave` 回一句错误文案时框不关、就地红字。改日期
  /// 挪出范围撞上别人是常事，先关框再弹 toast 会把刚敲的字一起丢掉。
  Future<_LogOutcome?> _textDialog({
    required String title,
    required String initial,
    required Future<String?> Function(String text) onSave,
    String? subtitle,
    DateTime? start,
    DateTime? end,
    bool pickRange = false,
    Future<String?> Function()? onDelete,
    String? hint = '这段时间在做什么',
    int minLines = 2,
  }) {
    return showDialog<_LogOutcome>(
      context: context,
      builder: (_) => _LogTextDialog(
        title: title,
        subtitle: subtitle,
        start: start,
        end: end,
        pickRange: pickRange,
        initial: initial,
        onSave: onSave,
        onDelete: onDelete,
        hint: hint,
        minLines: minLines,
      ),
    );
  }
}

/// 对话框的出口。`null`（pop 空值）= 取消。
class _LogOutcome {
  /// 保存 / 删除已经落盘，外面不用再做任何事。
  const _LogOutcome.done() : draftText = null;

  /// 要去日历上重圈：把这行草稿带出去，圈完重开框。
  const _LogOutcome.range(this.draftText);

  /// `done` 时为 null。
  final String? draftText;

  bool get wantsRange => draftText != null;
}

/// 一段记录的输入框：日期行（可选，带『改日期』）、正文、删除 / 取消 / 保存。
///
/// 单独做成 StatefulWidget 有两个原因：controller 得跟着框一起销毁；保存失败时
/// 要留在原地显示错误——让 `showDialog` 先关再重开会闪一下，键盘也跟着抖。
class _LogTextDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final DateTime? start;
  final DateTime? end;

  /// 日期行右端给不给『改日期』（只有记录段给；月记没有范围可改）。
  final bool pickRange;
  final String initial;
  final String? hint;
  final int minLines;

  /// 返回给用户看的错误文案；null = 已落盘，可以关框。
  final Future<String?> Function(String text) onSave;

  /// 非空才画『删除』。
  final Future<String?> Function()? onDelete;

  const _LogTextDialog({
    required this.title,
    required this.initial,
    required this.onSave,
    this.subtitle,
    this.start,
    this.end,
    this.pickRange = false,
    this.onDelete,
    this.hint,
    this.minLines = 2,
  });

  @override
  State<_LogTextDialog> createState() => _LogTextDialogState();
}

class _LogTextDialogState extends State<_LogTextDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  /// 保存 / 删除进行中：按钮先按住，避免连点落两条。
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() op) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await op();
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop(const _LogOutcome.done());
  }

  /// 收起这张框，把框里这行字交给外面去重圈。**不保存**：日期还没定。
  void _pickRange() {
    // 退场动画那一百多毫秒里框还在树上，连点第二下会把下面那条路由一起弹掉。
    if (_busy) return;
    _busy = true;
    Navigator.of(context).pop(_LogOutcome.range(_ctrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final start = widget.start;
    final end = widget.end;
    return AlertDialog(
      title: Text(widget.title),
      // 撞车那行红字可能很长（带着对家的正文），窄面板上再叠多行正文就容易溢出；
      // 这里让内容自己滚，框高不跟着内容长。
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (start != null && end != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _rangeText(start, end),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                  if (widget.pickRange)
                    Tooltip(
                      message: '改日期',
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(28, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.edit_calendar_outlined),
                          onPressed: _pickRange,
                        ),
                      ),
                    ),
                ],
              )
            else if (widget.subtitle != null)
              Text(widget.subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: widget.minLines,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: widget.hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.onDelete != null)
          TextButton(
            onPressed: _busy ? null : () => _run(widget.onDelete!),
            child: const Text('删除'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              _busy ? null : () => _run(() => widget.onSave(_ctrl.text.trim())),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 起止日期那行小字。跨年时末尾补上年份，否则「11 月 1 日 ~ 1 月 3 日」看着像倒序。
String _rangeText(DateTime a, DateTime b) {
  if (isSameDay(a, b)) return '${a.year} 年 ${a.month} 月 ${a.day} 日';
  final tail = a.year == b.year
      ? '${b.month} 月 ${b.day} 日'
      : '${b.year} 年 ${b.month} 月 ${b.day} 日';
  return '${a.year} 年 ${a.month} 月 ${a.day} 日 ~ $tail'
      '（${b.difference(a).inDays + 1} 天）';
}

// ---------- 几何 ----------

/// 一次布局算好的几何：周行、行高、每周的色带段。手势换算全靠它。
class _Layout {
  final List<_Week> weeks;
  final double rowH;
  final double dateH;

  /// 色带高度（半行上下）。压在数字后面，所以不占额外的道。
  final double barH;
  final double cellW;

  const _Layout({
    required this.weeks,
    required this.rowH,
    required this.dateH,
    required this.barH,
    required this.cellW,
  });

  double weekTop(int index) => index * rowH;

  static _Layout of(
    DateTime month,
    double width,
    double height,
    List<LogSegment> segments,
    List<Color> palette,
  ) {
    final first = DateTime(month.year, month.month, 1);
    final lead = (first.weekday + 6) % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final weekCount = ((lead + daysInMonth) + 6) ~/ 7;
    final rowH = height <= 0 ? 44.0 : height / weekCount;
    // 整行都是格子：数字居中，色带也居中铺在它后面。行高最紧的时候（六周的月份、
    // 320dp 的面板）带子收到 12dp，仍比数字大一圈。
    final dateH = rowH;
    final barH = math.min(20.0, math.max(12.0, rowH * 0.56));

    final weeks = <_Week>[];
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
      // 段只存对象引用，不存下标：命令通道按"起止日 + 原文"定位（见 LogSegmentRef）。
      // 颜色按起始日顺序取四色轮——相邻两段下标差 1，天然不同色。
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        if (segment.end.isBefore(weekStart) || segment.start.isAfter(weekEnd)) {
          continue;
        }
        final startCol =
            math.max(0, segment.start.difference(weekStart).inDays);
        final endCol = math.min(6, segment.end.difference(weekStart).inDays);
        if (startCol > endCol) continue;
        bands.add(_BandSegment(
          segment: segment,
          startCol: startCol,
          endCol: endCol,
          color: palette[i % palette.length],
          continuesLeft: segment.start.isBefore(weekStart),
          continuesRight: segment.end.isAfter(weekEnd),
        ));
      }
      weeks.add(_Week(cells: cells, weekStart: weekStart, bands: bands));
    }

    return _Layout(
      weeks: weeks,
      rowH: rowH,
      dateH: dateH,
      barH: barH,
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
  final LogSegment segment;
  final int startCol;
  final int endCol;
  final Color color;

  /// 这一段从上一周接过来 / 还要接到下一周去：那一侧的圆角去掉、贴到格子边。
  final bool continuesLeft;
  final bool continuesRight;

  const _BandSegment({
    required this.segment,
    required this.startCol,
    required this.endCol,
    required this.color,
    required this.continuesLeft,
    required this.continuesRight,
  });
}
