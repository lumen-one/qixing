import 'task.dart';

/// 回收站里的一条：任务本体 + 删除时刻。
///
/// 删除时刻只用于排序与展示，**不进 [Task]**——它不是任务事实，文件搬回
/// `.gtd/` 时就该消失（同 `.trash` 的那几个键）。放在 domain 是让 UI 与
/// application 都能用它而不用碰 repository（`test/architecture_test.dart`
/// 的 import 矩阵）。
class TrashEntry {
  final Task task;
  final DateTime deletedAt;

  const TrashEntry({required this.task, required this.deletedAt});
}
