import 'package:flutter/material.dart';

import '../../application/notes_markdown.dart';
import '../../application/notes_reader.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/notes_blocks.dart';

/// 灵感页（ui-interaction.md §6.2；页序见 `ui/panel_pages.dart`）。
/// 数据源 = 用户在 Obsidian 维护的指定 Markdown（路径在设置里配）。
/// **可就地编辑**：只替换正文段，frontmatter 与其他段落一个字符都不动（v1.29）。
/// 显示 frontmatter 闭合后到下一个 --- 之间的正文段；含 [[ 的整行屏蔽。
class NotesPanel extends StatefulWidget {
  final AppController controller;

  const NotesPanel({super.key, required this.controller});

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  final _textCtrl = TextEditingController();

  /// 编辑框的焦点。收起面板时要主动放掉它——否则输入法连接还开着，键盘会跟到
  /// 别的页上（与速记页同一套，见 [AppController.addPageTeardown]）。
  final _editorFocus = FocusNode();

  bool _editing = false;
  bool _saving = false;

  /// 本次编辑的草稿：屏蔽行不在输入框里，保存时由它插回（§6.2）。
  NotesDraft _draft = const NotesDraft('');

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    widget.controller.addPageTeardown(_releaseFocus);
    // 读到**帧后**再读笔记：本页是第一页，面板展开时就是在这里首次挂载，
    // 直接在 initState 里读会同步 notifyListeners → 祖先宿主 setState，
    // 框架报 "setState() called during build"（v1.24 页序一换就撞上了）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    widget.controller.removePageTeardown(_releaseFocus);
    _textCtrl.dispose();
    _editorFocus.dispose();
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  /// 面板收起之前只放焦点，**不退编辑态**：这一页是手工保存，收起面板不该被当成
  /// 取消，草稿与编辑态都留着，拉回来接着写。
  Future<void> _releaseFocus() async {
    if (_editorFocus.hasFocus) _editorFocus.unfocus();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await widget.controller.refreshNotes();
    if (mounted) setState(() {});
  }

  /// 进编辑态：初值 = 正文段去掉被 `[[` 屏蔽的行（与只读态看到的是同一份）。
  /// 那些行留在 [_draft] 里，保存时按原行号插回，不会被抹掉（§6.2）。
  void _startEdit(NotesReadResult r) {
    _draft = buildNotesDraft(r.bodyLines);
    _textCtrl.text = _draft.text;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    // 先把焦点放掉：输入框马上要被换掉，别等卸载才关输入法连接。
    if (_editorFocus.hasFocus) _editorFocus.unfocus();
    setState(() => _editing = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.controller.saveNotes(_draft.merge(_textCtrl.text));
    if (!mounted) return;
    if (ok && _editorFocus.hasFocus) _editorFocus.unfocus();
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('灵感没存上：文件不可写，或 frontmatter 未闭合')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = widget.controller.notes;

    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          // 功能栏只占一行（§6.2）：面板窄，页头多留一圈白就少看一段正文。
          padding: const EdgeInsets.fromLTRB(18, 2, 10, 2),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              // 页名归面板头，这里不重复；只标"正在编辑"这个瞬时状态。
              if (_editing) Text('编辑中', style: theme.textTheme.labelMedium),
              const Spacer(),
              if (_editing) ...[
                _barButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: _saving ? null : _cancelEdit,
                ),
                _barButton(
                  tooltip: '保存',
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  onPressed: _saving ? null : _save,
                ),
              ] else ...[
                // 速记覆盖页的显式入口（§6.13）：下拉那一下没有视觉线索，
                // 这一页的功能栏有位置就补一颗。编辑态里不摆——那条手势在编辑态
                // 本来就不接，图标也不该把人带离没存下的字。
                if (widget.controller.speedNoteService != null)
                  _barButton(
                    tooltip: '速记',
                    icon: const Icon(Icons.sticky_note_2_outlined),
                    onPressed: () =>
                        widget.controller.openSpeedNote(instant: false),
                  ),
                if (result.canEdit)
                  _barButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _startEdit(result),
                  ),
                _barButton(
                  tooltip: '重新读取',
                  icon: const Icon(Icons.refresh),
                  onPressed: _load,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _editing
              ? _editor(theme)
              : _withSpeedPull(_viewer(result)),
        ),
      ],
    );
  }

  /// 灵感页是速记的入口（§6.13）：**已经滚到顶**还继续往下拉，就把行程喂给控制器。
  ///
  /// 与今日页进编排同一套判据（[today_panel] 的 `_withPlanPull`）：只认手指拖
  /// （`dragDetails != null`），鼠标滚轮与触控板"滚到头继续滚"是常态，认了就是
  /// 天天误触；`depth != 0` 的内层通知跳过。
  Widget _withSpeedPull(Widget child) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.depth != 0) return false;
          if (n is OverscrollNotification && n.dragDetails != null) {
            // 顶部继续下拉时 overscroll 是负的（像素已经不能再减）。
            widget.controller.pullSpeedNote(-n.overscroll);
          } else if (n is ScrollEndNotification) {
            widget.controller
                .settleSpeedNote(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
          }
          return false;
        },
        child: child,
      );

  /// 功能栏那颗图标钮：收到 34dp。M3 默认 48dp 见方，一行图标就吃掉 62dp 高，
  /// 一半是留白——窄面板上这些留白是正文的代价。
  Widget _barButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) =>
      IconButton(
        tooltip: tooltip,
        iconSize: 18,
        style: IconButton.styleFrom(
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: icon,
        onPressed: onPressed,
      );

  Widget _editor(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        child: TextField(
          controller: _textCtrl,
          focusNode: _editorFocus,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: '写点什么…',
          ),
        ),
      );

  Widget _viewer(NotesReadResult result) =>
      switch (result.status) {
        NotesStatus.notConfigured => const _Empty(
            icon: Icons.menu_book_outlined,
            text: '未找到灵感，去设置选择文件',
          ),
        NotesStatus.notFound => const _Empty(
            icon: Icons.file_present,
            text: '未找到灵感，去设置选择文件',
          ),
        NotesStatus.empty => const _Empty(
            icon: Icons.filter_alt_off_outlined,
            text: '这一段没有可显示的内容',
          ),
        NotesStatus.ok => _NotesDocument(lines: result.lines),
      };
}

/// 只读态正文：按块渲染（认得哪些语法见 docs/panels/notes.md）。
/// 解析在 [parseNotesMarkdown]，这里只管长什么样。
class _NotesDocument extends StatelessWidget {
  final List<String> lines;

  const _NotesDocument({required this.lines});

  @override
  Widget build(BuildContext context) {
    final blocks = parseNotesMarkdown(lines);
    return ListView.builder(
      // 短正文也要能拖出 overscroll：下拉进速记靠它（§6.13）。
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
      itemCount: blocks.length,
      itemBuilder: (context, i) => Padding(
        padding: EdgeInsets.only(
            top: i == 0 ? 0 : _gapBetween(blocks[i - 1], blocks[i])),
        child: NotesBlockView(block: blocks[i]),
      ),
    );
  }

  /// 列表项之间挨紧，换类别的块之间松开。
  static double _gapBetween(NotesBlock prev, NotesBlock cur) =>
      _isList(prev) && _isList(cur) ? 2 : 8;

  static bool _isList(NotesBlock b) =>
      b.kind == NotesBlockKind.bullet || b.kind == NotesBlockKind.ordered;
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Empty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (ctx, constraints) => SingleChildScrollView(
          // 未配置 / 空态也得能下拉（§6.13）：centered 的一块没有滚动，
          // 就永远没有 overscroll，速记那一页等于进不去。
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: FadeIn(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon,
                        size: 40,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(text),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
