import '../domain/speednote.dart';
import '../repository/speednote_repository.dart';

/// 速记的应用服务（panels/speednote.md §6.13）。
///
/// **与 TaskService / PlanService 完全独立**：一条速记不是任务，这里不重锚调度、
/// 不发领域事件、不碰 `.gtd/`。它只做一件事：读整份 `速记.md`、改一条、整份写回。
///
/// 每个命令都是"**先读盘 → 改 → 整份写回**"：两个引擎（应用内 / 悬浮窗）可能同时写
/// 同一个文件，读一遍再改能把"另一个引擎刚写的别的速记"带上，不至于被本地旧内存态
/// 抹掉（与编排、主线同一套理由）。
class SpeedNoteService {
  final SpeedNoteRepository repo;

  List<SpeedNote> _notes = const [];

  SpeedNoteService({required this.repo});

  /// 解析告警（诊断用）。
  List<String> get warnings => repo.warnings;

  /// 全部速记，**顺序 = 文件顺序 = 标签栏顺序**。
  List<SpeedNote> get notes => _notes;

  SpeedNote? byId(String? id) {
    if (id == null) return null;
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 读盘（启动 / 文件变更 / 打开覆盖页时调；幂等）。
  Future<void> load() async {
    _notes = await repo.loadAll();
  }

  /// 新建一条空速记，追加到末尾并返回它。
  Future<SpeedNote> create({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final disk = await repo.loadAll();
    final note = SpeedNote(
      id: newSpeedNoteId(at, {for (final n in disk) n.id}),
      created: at,
    );
    final next = [...disk, note];
    await repo.saveAll(next);
    _notes = next;
    return note;
  }

  /// 改正文（自动保存走这里）。
  Future<void> saveBody(String id, String body) =>
      _mutate(id, (n) => n.body == body ? n : n.copyWith(body: body));

  /// 改标签名（空字符串 = 回到『未命名』）。
  Future<void> rename(String id, String title) {
    final t = title.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    return _mutate(id, (n) => n.title == t ? n : n.copyWith(title: t));
  }

  /// 删一条。撤销靠 [restore] 把它按原位置塞回去。
  Future<void> delete(String id) async {
    final disk = await repo.loadAll();
    final next = [
      for (final n in disk)
        if (n.id != id) n,
    ];
    if (next.length == disk.length) return;
    await repo.saveAll(next);
    _notes = next;
  }

  /// 撤销删除：按 [index] 插回原位（越界则落到末尾）。
  Future<void> restore(SpeedNote note, {int? index}) async {
    final disk = [
      for (final n in await repo.loadAll())
        if (n.id != note.id) n,
    ];
    final at = (index ?? disk.length).clamp(0, disk.length);
    final next = [...disk]..insert(at, note);
    await repo.saveAll(next);
    _notes = next;
  }

  /// 读盘 → 换掉那一条 → 整份写回。**不动别人的顺位**：标签栏顺序就是文件顺序，
  /// 改正文不该让它挪位置。
  Future<void> _mutate(String id, SpeedNote Function(SpeedNote) change) async {
    final disk = await repo.loadAll();
    var hit = false;
    final next = <SpeedNote>[];
    for (final n in disk) {
      if (n.id != id) {
        next.add(n);
        continue;
      }
      hit = true;
      final changed = change(n);
      // 没变就不落盘：自动保存会被切标签、退出覆盖页反复触发，
      // 每次都重写一遍整份文件只是白写盘。
      if (identical(changed, n) || _same(n, changed)) {
        next.add(n);
        return;
      }
      next.add(changed);
    }
    if (!hit) return;
    await repo.saveAll(next);
    _notes = next;
  }

  static bool _same(SpeedNote a, SpeedNote b) =>
      a.id == b.id && a.title == b.title && a.body == b.body;
}
