import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/notes_markdown.dart';
import '../../domain/speednote.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/notes_blocks.dart';

/// 速记覆盖页（panels/speednote.md §6.13）。
///
/// 一块覆盖页装 N 个标签页，一条速记一个标签。展示态把 `#` 标题当折叠头，编辑态是
/// 整篇一个输入框、`#` 行边打边放大。数据在 `速记.md`（[SpeedNote]），这一层只管
/// 长什么样、什么时候落盘。
///
/// **自动保存**：切标签、点『完成』、退出覆盖页、面板收起时写盘。页面把自己的
/// "收拾动作"（落盘 + 放焦点）注册进控制器，关页之前控制器会等它跑完——写盘时机
/// 只有这一处，别在别处再存一遍。
class SpeedNoteOverlay extends StatefulWidget {
  final AppController controller;

  /// 退出（『返回』/ 上滑退出都走它；返回键由宿主判）。
  final Future<void> Function() onClose;

  const SpeedNoteOverlay({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<SpeedNoteOverlay> createState() => _SpeedNoteOverlayState();
}

class _SpeedNoteOverlayState extends State<SpeedNoteOverlay> {
  /// 编辑态的正文。用带标题样式的 controller（`#` 行边打边变大）。
  final _bodyCtrl = _HeadingTextController();

  final _editorFocus = FocusNode();

  /// 展示态的纵向滚动（目录条跳转要拿它的位置）。
  final _scroll = ScrollController();

  /// 收起来的标题（按行号记）。不落盘，退出覆盖页即清空。
  final Set<int> _collapsed = {};

  /// 目录条跳转要用的锚点，一个标题一个。
  final Map<int, GlobalKey> _headingKeys = {};

  /// 标签栏每一颗的锚点：横滑切到视野外的那条时，把它滚进来。
  final Map<String, GlobalKey> _tabKeys = {};

  /// 横向拖动累计的位移（松手时按它和速度判方向）。
  double _swipeDx = 0;

  bool _editing = false;

  /// 输入框里这段字属于哪一条速记。与当前标签不一致 = 还没对齐，别拿它写盘。
  String? _editorNoteId;

  /// 刚跳过去的标题行（闪一下底色）。
  int? _flash;
  Timer? _flashTimer;

  AppController get _c => widget.controller;

  SpeedNote? get _note => _c.currentSpeedNote;

  @override
  void initState() {
    super.initState();
    _c.addPageTeardown(_releaseEditing);
  }

  @override
  void dispose() {
    _c.removePageTeardown(_releaseEditing);
    // 兜一道：有路绕过控制器把页面拆掉时，焦点别跟着节点一起消失（输入法连接
    // 那时才关，键盘会留在别的页上）。
    if (_editorFocus.hasFocus) _editorFocus.unfocus();
    _flashTimer?.cancel();
    _bodyCtrl.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 落盘

  /// 把输入框里的字写回当前那条。没有在编辑 / 没有改动 → 什么都不做。
  Future<void> _flush() async {
    final note = _note;
    if (!_editing || note == null || _editorNoteId != note.id) return;
    final text = _bodyCtrl.text;
    if (text == note.body) return;
    await _c.saveSpeedNoteBody(note.id, text);
  }

  /// 收拾：落盘，然后**放掉焦点**。
  ///
  /// 键盘只认"输入法连接被关掉"，而那件事发生在输入框装卸时。退场动画要 200ms、
  /// 悬浮壳摘窗口更早，等卸载来收键盘就来不及了——所以在这一步主动 `unfocus`。
  /// **编辑态不退**：页面紧接着就滑走了，中途把正文换成展示态会看见字重排一下；
  /// 『完成』那边退编辑态是它自己的事。
  Future<void> _releaseEditing() async {
    await _flush();
    if (!mounted) return;
    if (_editorFocus.hasFocus) _editorFocus.unfocus();
  }

  // ------------------------------------------------------------ 标签

  Future<void> _select(String id) async {
    if (_note?.id == id) return;
    await _flush();
    if (!mounted) return;
    setState(() {
      _editing = false;
      _editorNoteId = null;
      _collapsed.clear();
      _headingKeys.clear();
      _flash = null;
    });
    _c.selectSpeedNote(id);
    _revealTab(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// 横滑翻一条：到头就停住并说一声，免得被当成手势没生效。
  Future<void> _stepNote(int delta) async {
    final notes = _c.speedNotes;
    // 只有一条时两头都是尽头，提示只会让人更糊。
    if (notes.length < 2) return;
    final i = notes.indexWhere((n) => n.id == _note?.id);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0) {
      _toast('已经是第一条');
      return;
    }
    if (j >= notes.length) {
      _toast('已经是最后一条');
      return;
    }
    await _select(notes[j].id);
  }

  /// 把当前标签滚进视线：横滑过去的那条可能在标签栏外面。点标签进来的本来就在
  /// 视野里，`ensureVisible` 不会动，所以两条路都走这一处。
  void _revealTab(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tabKeys[id]?.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

  Future<void> _add() async {
    await _flush();
    final note = await _c.addSpeedNote();
    if (!mounted) return;
    if (note == null) {
      _toast('新建失败：速记文件不可写');
      return;
    }
    setState(() {
      _editing = true;
      _editorNoteId = note.id;
      _collapsed.clear();
      _headingKeys.clear();
      _bodyCtrl.text = '';
    });
    _focusEditor(atEnd: false);
  }

  Future<void> _delete(SpeedNote note) async {
    final index = _c.speedNotes.indexWhere((n) => n.id == note.id);
    // 先退编辑态：那点字不能写回一条已经删掉的速记。
    if (_editorNoteId == note.id) setState(() => _editing = false);
    await _c.removeSpeedNote(note.id);
    if (!mounted) return;
    _tabKeys.remove(note.id);
    _headingKeys.clear();
    _collapsed.clear();
    setState(() => _flash = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已删除「${note.displayLabel}」'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => unawaited(_c.restoreSpeedNote(note, index: index)),
      ),
    ));
  }

  Future<void> _renameTab(SpeedNote note) async {
    final text = await _askText(
      title: '标签名',
      initial: note.title,
      hint: '未命名',
    );
    if (text == null) return;
    await _c.renameSpeedNote(note.id, text);
  }

  // ------------------------------------------------------------ 编辑

  void _startEdit(SpeedNote note) {
    setState(() {
      _editing = true;
      _editorNoteId = note.id;
      _collapsed.clear();
      _flash = null;
      _bodyCtrl.text = note.body;
    });
    _focusEditor(atEnd: true);
  }

  Future<void> _finishEdit() async {
    await _releaseEditing();
    if (!mounted) return;
    setState(() => _editing = false);
  }

  void _focusEditor({required bool atEnd}) {
    _bodyCtrl.selection = TextSelection(
      baseOffset: atEnd ? _bodyCtrl.text.length : 0,
      extentOffset: atEnd ? _bodyCtrl.text.length : 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus.requestFocus();
    });
  }

  // ------------------------------------------------------------ 标题

  Future<void> _headingMenu(NotesHeading h, SpeedNote note) async {
    // 菜单里的名字用 `#` 的个数说话：升一级就是少一个井号。
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      h.text.isEmpty ? '（空标题）' : h.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                  ),
                  Text('#' * h.level,
                      style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            _menuTile(ctx, Icons.edit_outlined, '改名', 'rename', enabled: true),
            _menuTile(ctx, Icons.north, '升一级', 'up', enabled: h.level > 1),
            _menuTile(ctx, Icons.south, '降一级', 'down', enabled: h.level < 2),
            _menuTile(ctx, Icons.delete_outline, '删除这一节', 'delete',
                enabled: true),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    final lines = note.body.split('\n');
    final headings = scanNotesHeadings(lines);
    switch (action) {
      case 'rename':
        final text = await _askText(
          title: '标题',
          initial: h.text,
          hint: '标题',
          allowEmpty: false,
        );
        if (text == null || text.trim().isEmpty) return;
        lines[h.line] = '${'#' * h.level} ${_oneLine(text)}';
        await _writeBody(note, lines);
      case 'up':
        if (h.level <= 1) return;
        lines[h.line] = '${'#' * (h.level - 1)} ${h.text}'.trimRight();
        await _writeBody(note, lines);
      case 'down':
        if (h.level >= 2) return;
        lines[h.line] = '${'#' * (h.level + 1)} ${h.text}'.trimRight();
        await _writeBody(note, lines);
      case 'delete':
        final end = _sectionEnd(headings, h, lines.length);
        final rest = [...lines]..removeRange(h.line, end);
        // 删空的尾巴（连着几个空行）顺手收一下，免得留下大片空白。
        while (rest.isNotEmpty && rest.last.trim().isEmpty) {
          rest.removeLast();
        }
        final before = note.body;
        await _writeBody(note, rest);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已删除「${h.text.isEmpty ? '空标题' : h.text}」这一节'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => unawaited(_c.saveSpeedNoteBody(note.id, before)),
          ),
        ));
    }
  }

  /// 这一节的范围：从标题行到下一个同级或更高级标题之前（没有就到末尾）。
  static int _sectionEnd(
      List<NotesHeading> headings, NotesHeading h, int lineCount) {
    for (final other in headings) {
      if (other.line <= h.line) continue;
      if (other.level <= h.level) return other.line;
    }
    return lineCount;
  }

  Future<void> _writeBody(SpeedNote note, List<String> lines) async {
    final body = lines.join('\n');
    // 行号移位了：收起来的那些记的是旧行号，全展开最省事。
    setState(() {
      _collapsed.clear();
      _flash = null;
    });
    await _c.saveSpeedNoteBody(note.id, body);
  }

  void _jump(NotesHeading h) {
    final ctx = _headingKeys[h.line]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: 0.02,
      );
    }
    _flashTimer?.cancel();
    setState(() => _flash = h.line);
    _flashTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  // ------------------------------------------------------------ 小工具

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> _askText({
    required String title,
    required String initial,
    required String hint,
    bool allowEmpty = true,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => _TextPromptDialog(
          title: title,
          initial: initial,
          hint: hint,
          allowEmpty: allowEmpty,
        ),
      );

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  Widget _menuTile(
    BuildContext ctx,
    IconData icon,
    String label,
    String value, {
    required bool enabled,
  }) =>
      ListTile(
        enabled: enabled,
        leading: Icon(icon,
            color: enabled
                ? AppColors.accent
                : Theme.of(ctx).disabledColor),
        title: Text(label),
        onTap: enabled ? () => Navigator.of(ctx).pop(value) : null,
      );

  // ------------------------------------------------------------ 组装

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final notes = _c.speedNotes;
        final note = _note;
        return Material(
          color: theme.colorScheme.surface,
          child: Column(
            children: [
              _header(theme, notes.length),
              const Divider(height: 1),
              _tabBar(theme, notes, note),
              if (!_editing && note != null) _outlineBar(theme, note),
              const Divider(height: 1),
              Expanded(
                child: note == null
                    ? _empty(theme)
                    : (_editing
                        ? _editor(theme)
                        : _swipeNotes(_viewer(theme, note))),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(ThemeData theme, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
        child: Row(
          children: [
            _iconButton(Icons.arrow_back, '返回',
                () => unawaited(widget.onClose())),
            const SizedBox(width: 2),
            // 视图名：只有「速记」一段时只是一个标题，不是按钮。将来加新页面就在
            // 这一行变成切换（与编排 / 支线同构）。
            Expanded(
              child: Text('速记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall),
            ),
            if (_editing)
              _iconButton(Icons.check, '完成', () => unawaited(_finishEdit()))
            else if (_note != null)
              _iconButton(Icons.edit_outlined, '编辑',
                  () => _startEdit(_note!)),
            const SizedBox(width: 2),
            Text('$count 条',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onPressed) =>
      SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 18,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            minimumSize: const Size(32, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      );

  /// 标签栏：浏览器式，横向滚动，末尾一颗 `+`。
  Widget _tabBar(ThemeData theme, List<SpeedNote> notes, SpeedNote? current) {
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
        itemCount: notes.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, i) {
          if (i == notes.length) {
            return SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 18,
                tooltip: '新建速记',
                style: IconButton.styleFrom(
                  minimumSize: const Size(30, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                icon: const Icon(Icons.add),
                onPressed: () => unawaited(_add()),
              ),
            );
          }
          final n = notes[i];
          final active = current?.id == n.id;
          return GestureDetector(
            // 锚点按 id 存：横滑切到视野外的那条时要把它滚进来。
            key: _tabKeys.putIfAbsent(n.id, () => GlobalKey()),
            onTap: () => unawaited(_select(n.id)),
            onLongPress: () => unawaited(_renameTab(n)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(minWidth: 44, maxWidth: 148),
              height: 30,
              padding: EdgeInsets.only(left: 9, right: active ? 1 : 9),
              decoration: BoxDecoration(
                color: active
                    ? scheme.surfaceContainerHighest
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: active
                      ? Colors.transparent
                      : scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      n.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: active
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (active)
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 13,
                        tooltip: '删除这条速记',
                        style: IconButton.styleFrom(
                          minimumSize: const Size(24, 24),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(Icons.close,
                            color: scheme.onSurfaceVariant),
                        onPressed: () => unawaited(_delete(n)),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 目录条：正文里有 2 个及以上标题才出现。只有一个标题时它只是重复第一行。
  Widget _outlineBar(ThemeData theme, SpeedNote note) {
    final headings = scanNotesHeadings(note.body.split('\n'))
        .where((h) => h.text.isNotEmpty)
        .toList();
    if (headings.length < 2) return const SizedBox.shrink();
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
        itemCount: headings.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final h = headings[i];
          final active = _flash == h.line;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _jump(h),
            child: Center(
              child: Text(
                h.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: active
                      ? AppColors.accent
                      : (h.level > 1
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.8)
                          : scheme.onSurfaceVariant),
                  fontWeight: h.level == 1 ? FontWeight.w600 : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(ThemeData theme) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
        children: [
          Icon(Icons.sticky_note_2_outlined,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text('还没有速记',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 14),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: () => unawaited(_add()),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建一条'),
            ),
          ),
        ],
      );

  // ------------------------------------------------------------ 展示态

  /// 正文区左右横滑 = 切上一条 / 下一条。
  ///
  /// **只包展示态**：编辑态里横向拖动是移光标、选字，抢走就写不了字了。标签栏与
  /// 目录条是两条自己会滚的横向列表，也不经过这里。纵向滚动与它正交，互不抢手。
  Widget _swipeNotes(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _swipeDx = 0,
      onHorizontalDragUpdate: (d) => _swipeDx += d.delta.dx,
      onHorizontalDragCancel: () => _swipeDx = 0,
      onHorizontalDragEnd: (d) {
        final dx = _swipeDx;
        final v = d.primaryVelocity ?? 0;
        _swipeDx = 0;
        // 与记录页翻页同一个判据：走过 48dp 或快甩就算数。
        if (dx < -48 || v < -500) {
          unawaited(_stepNote(1));
        } else if (dx > 48 || v > 500) {
          unawaited(_stepNote(-1));
        }
      },
      child: child,
    );
  }

  Widget _viewer(ThemeData theme, SpeedNote note) {
    final lines = note.body.split('\n');
    final headings = scanNotesHeadings(lines);
    final byLine = {for (final h in headings) h.line: h};

    final items = <Widget>[];
    var chunk = <String>[];

    void flushChunk() {
      if (chunk.isEmpty) return;
      final blocks = parseNotesMarkdown(chunk);
      for (var i = 0; i < blocks.length; i++) {
        final gap = i == 0
            ? (items.isEmpty ? 0.0 : 8.0)
            : _gapBetween(blocks[i - 1], blocks[i]);
        items.add(Padding(
          padding: EdgeInsets.only(top: gap),
          child: NotesBlockView(block: blocks[i]),
        ));
      }
      chunk = <String>[];
    }

    var i = 0;
    while (i < lines.length) {
      final h = byLine[i];
      if (h == null) {
        chunk.add(lines[i]);
        i++;
        continue;
      }
      flushChunk();
      final end = _sectionEnd(headings, h, lines.length);
      final hasChildren = _hasContent(lines, i + 1, end);
      final collapsed = _collapsed.contains(i);
      items.add(_headingRow(theme, h, hasChildren, collapsed));
      if (collapsed) {
        i = end;
        continue;
      }
      i++;
    }
    flushChunk();

    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
        children: [
          Text('这一条还是空的',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text('点右上角那颗铅笔开始写；`#` 开头的行就是标题。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      );
    }

    return NotificationListener<ScrollNotification>(
      // 滚到底再继续上滑 = 退出（与编排同一个判据：只在"末尾之后"算退出）。
      // **按轴筛，不按 depth**：这一页外面没有横向 PageView，但保持与编排一致的写法，
      // 免得将来套进去时又被 depth 吃掉。
      onNotification: (n) {
        if (n.metrics.axis != Axis.vertical) return false;
        if (n is OverscrollNotification &&
            n.dragDetails != null &&
            n.overscroll > 0) {
          _c.pullSpeedNoteExit(n.overscroll);
        } else if (n is ScrollEndNotification) {
          _c.settleSpeedNoteExit(
              n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
        }
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: items,
        ),
      ),
    );
  }

  Widget _headingRow(
      ThemeData theme, NotesHeading h, bool hasChildren, bool collapsed) {
    final scheme = theme.colorScheme;
    final flashing = _flash == h.line;
    return Container(
      key: _headingKeys.putIfAbsent(h.line, () => GlobalKey()),
      decoration: BoxDecoration(
        color: flashing
            ? AppColors.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: hasChildren
            ? () => setState(() {
                  if (!_collapsed.remove(h.line)) _collapsed.add(h.line);
                })
            : null,
        onLongPress: () => unawaited(_headingMenu(h, _note!)),
        child: Padding(
          padding: EdgeInsets.only(top: 8, bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 16,
                height: 22,
                child: hasChildren
                    ? Icon(
                        collapsed ? Icons.chevron_right : Icons.expand_more,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      )
                    : null,
              ),
              Expanded(
                child: NotesBlockView(
                  block: NotesBlock(
                    NotesBlockKind.heading,
                    level: h.level,
                    spans: parseNotesInline(h.text),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 这一节里有没有东西可收（空标题下面什么都没有，就不画三角）。
  static bool _hasContent(List<String> lines, int from, int end) {
    for (var i = from; i < end && i < lines.length; i++) {
      if (lines[i].trim().isNotEmpty) return true;
    }
    return false;
  }

  static double _gapBetween(NotesBlock prev, NotesBlock cur) =>
      _isList(prev) && _isList(cur) ? 2 : 8;

  static bool _isList(NotesBlock b) =>
      b.kind == NotesBlockKind.bullet || b.kind == NotesBlockKind.ordered;

  // ------------------------------------------------------------ 编辑态

  Widget _editor(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
        child: TextField(
          controller: _bodyCtrl,
          focusNode: _editorFocus,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: (theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14))
              .copyWith(height: 1.6),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: '写点什么…',
          ),
        ),
      );
}

/// 一句文字的输入框（标签改名 / 标题改名共用）。
///
/// 单独做成 StatefulWidget 是为了 controller 的归属：在 `showDialog(...).whenComplete`
/// 里销毁会在退场动画还没跑完时炸掉（TextField 那时还在树上）。
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String hint;
  final bool allowEmpty;

  const _TextPromptDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.allowEmpty,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.allowEmpty && _ctrl.text.trim().isEmpty) return;
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: widget.hint, isDense: true),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(onPressed: _submit, child: const Text('好')),
        ],
      );
}

/// 编辑态的正文输入：`#` 开头的行边打边放大加粗（只是显示，文件里仍是原文）。
///
/// 单个输入框能做到的只有字号与字重；"收起"要藏字，光标会乱，所以折叠只在展示态。
/// 输入法组合串（中文候选）仍照默认那样加下划线——自绘 `buildTextSpan` 最容易丢的
/// 就是这一条，特意留着。
class _HeadingTextController extends TextEditingController {
  static final RegExp _headingRe = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+|$)');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final text = this.text;
    if (text.isEmpty) return TextSpan(style: base, text: '');

    final composing = (withComposing &&
            value.composing.isValid &&
            !value.composing.isCollapsed)
        ? value.composing
        : null;

    final spans = <TextSpan>[];
    var start = 0;
    for (final line in text.split('\n')) {
      final end = start + line.length;
      final level = _levelOf(line);
      final lineStyle = _styleFor(base, level);
      _emit(spans, text, start, end, lineStyle, composing);
      if (end < text.length) {
        spans.add(TextSpan(text: '\n', style: lineStyle));
        start = end + 1;
      } else {
        start = end;
      }
    }
    return TextSpan(style: base, children: spans);
  }

  static int _levelOf(String line) {
    final m = _headingRe.firstMatch(line);
    return m == null ? 0 : m.group(1)!.length;
  }

  static TextStyle _styleFor(TextStyle base, int level) {
    if (level == 0) return base;
    final size = base.fontSize ?? 14;
    final scale = switch (level) {
      1 => 1.45,
      2 => 1.28,
      3 => 1.14,
      _ => 1.0,
    };
    return base.copyWith(
      fontSize: size * scale,
      fontWeight: level <= 3 ? FontWeight.w700 : FontWeight.w600,
      height: 1.4,
    );
  }

  /// 把一段文字按输入法组合区切开发出来（组合中的那截加下划线）。
  static void _emit(
    List<TextSpan> out,
    String text,
    int start,
    int end,
    TextStyle style,
    TextRange? composing,
  ) {
    if (start >= end) return;
    if (composing == null ||
        composing.end <= start ||
        composing.start >= end) {
      out.add(TextSpan(text: text.substring(start, end), style: style));
      return;
    }
    final cStart = composing.start.clamp(start, end);
    final cEnd = composing.end.clamp(start, end);
    if (cStart > start) {
      out.add(TextSpan(text: text.substring(start, cStart), style: style));
    }
    out.add(TextSpan(
      text: text.substring(cStart, cEnd),
      style: style.copyWith(decoration: TextDecoration.underline),
    ));
    if (cEnd < end) {
      out.add(TextSpan(text: text.substring(cEnd, end), style: style));
    }
  }
}
