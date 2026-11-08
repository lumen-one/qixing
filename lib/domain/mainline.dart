/// 主线（ui-interaction.md §6.9；存储格式见 formats/mainline.md B.6）。
///
/// 三层边界：**主线与任务池不相交**——行为链上的步骤不是 Task，不进调度、
/// 不占工时、不响提醒。与记录也不相交：日历上的圈与月记住在另一份数据
/// （`domain/logbook.dart`），这里一行都不碰。
///
/// 一条主线 = 标题 + 一串步骤（行为链）。
/// 归档 = [Mainline.completedAt] 或 [Mainline.abandonedAt] 有值，**只改状态、不删数据**
/// （`docs/decisions/2026-11-07-mainline-abandon.md`）。
library;

/// 行为链上的一步。
///
/// **完成状态由复选框来**（[done]），[doneAt] 只是完成时刻：人在 Obsidian 里
/// 手改 `- [x] 某步` 而不写 `完成` 时，这一步算完成、但不进自动流水
/// （没有时刻就归不到哪一天，不猜）。
class MainlineStep {
  final String title;

  final bool done;

  /// 完成时刻；null = 完成但没有时刻（手改复选框的情形）。
  final DateTime? doneAt;

  /// 写在这一步上的备注——用户手写的几句话挂在这里，不另存一份。
  final String note;

  const MainlineStep({
    required this.title,
    this.done = false,
    this.doneAt,
    this.note = '',
  });

  MainlineStep copyWith({
    String? title,
    bool? done,
    DateTime? doneAt,
    bool clearDoneAt = false,
    String? note,
  }) {
    return MainlineStep(
      title: title ?? this.title,
      done: done ?? this.done,
      doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
      note: note ?? this.note,
    );
  }

  @override
  String toString() => 'MainlineStep($title, done: $done, at: $doneAt)';
}

/// 一条主线。
class Mainline {
  final String id;
  final String title;
  final DateTime created;

  /// 归档时刻；null = 在跑（**同时只有一条**在跑）。
  final DateTime? completedAt;

  /// 废弃时刻；与 [completedAt] 一样是归档，区别只在于"做完了"还是"不做了"。
  /// 两个都为 null 才是在跑；两个都有值（手改出来的边角）按完成算。
  final DateTime? abandonedAt;

  final List<MainlineStep> steps;

  Mainline({
    required this.id,
    required this.title,
    required this.created,
    this.completedAt,
    this.abandonedAt,
    List<MainlineStep> steps = const [],
  }) : steps = List.unmodifiable(steps);

  /// 新建一条（[stepTitles] 可直接给几步空链）。
  factory Mainline.fresh({
    required String id,
    required String title,
    required DateTime created,
    List<String> stepTitles = const [],
  }) {
    return Mainline(
      id: id,
      title: title,
      created: created,
      steps: [for (final t in stepTitles) MainlineStep(title: t)],
    );
  }

  bool get isActive => completedAt == null && abandonedAt == null;

  /// 做完归档（[completedAt] 有值）。两个时刻都有值时按完成算。
  bool get isCompleted => completedAt != null;

  /// 废弃归档：只在没有完成时刻时成立——手改出两个都有值的条目不冒充两种结局。
  bool get isAbandoned => completedAt == null && abandonedAt != null;

  /// 归档时刻（完成优先）；null = 在跑。归档列表按它从新到旧排。
  DateTime? get archivedAt => completedAt ?? abandonedAt;

  /// 归档列表那一行右侧的徽标文字。
  String get archiveLabel => isAbandoned ? '已废弃' : '已完成';

  int get totalSteps => steps.length;

  int get doneSteps => steps.where((s) => s.done).length;

  /// 0–1；没有步骤时是 0（空链不是"完成"）。
  double get progress => totalSteps == 0 ? 0 : doneSteps / totalSteps;

  /// **空链不算勾完**——否则新建一条空主线就能直接归档。
  bool get isAllDone => steps.isNotEmpty && doneSteps == totalSteps;

  String get progressText => '$doneSteps/$totalSteps';

  /// 下一个该做的步骤下标（第一个没勾的）；全勾完 / 空链 → null。
  int? get nextStepIndex {
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].done) return i;
    }
    return null;
  }

  Mainline copyWith({
    String? title,
    DateTime? completedAt,
    DateTime? abandonedAt,
    bool clearCompleted = false,
    bool clearAbandoned = false,
    List<MainlineStep>? steps,
  }) {
    return Mainline(
      id: id,
      title: title ?? this.title,
      created: created,
      completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
      abandonedAt: clearAbandoned ? null : (abandonedAt ?? this.abandonedAt),
      steps: steps ?? this.steps,
    );
  }

  @override
  String toString() => 'Mainline($id, $title, $progressText, '
      '${steps.length} steps)';
}
