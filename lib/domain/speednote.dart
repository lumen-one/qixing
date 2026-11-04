/// 速记（panels/speednote.md §6.13；存储格式见 docs/formats/speednote.md）。
///
/// 一条速记 = 一个标签页：id + 标签名 + 正文 markdown。与任务、主线、编排都不相交
/// ——不产生任务、不进调度、不响提醒、不写 `.gtd/`。正文就是数据本身，应用保存时
/// 按模型整份重写。
library;

import 'dart:math';

/// 一条速记。
class SpeedNote {
  /// `sn-20261104-3f9c`（见 [newSpeedNoteId]）。
  final String id;

  /// 标签上那个名字；空 = 未命名（界面上显示『未命名』）。
  final String title;

  final DateTime created;

  /// markdown 原文。`#` 标题、列表、引用、代码块都原样存着，不做规范化。
  final String body;

  const SpeedNote({
    required this.id,
    this.title = '',
    required this.created,
    this.body = '',
  });

  bool get isUntitled => title.trim().isEmpty;

  /// 标签页上显示的字。
  String get tabLabel => isUntitled ? '未命名' : title.trim();

  /// 正文里第一个 `#` 标题的文字；没有 → null。
  ///
  /// 只给"标签名还是空的"那一条用：新建之后人往往先写一行 `# 十一月的计划`，
  /// 那不叫"没命名"。文件里的 `title` 仍以人显式改过的为准，不从正文回写。
  String? get firstHeading {
    for (final line in body.split('\n')) {
      final m = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*))?$').firstMatch(line);
      if (m == null) continue;
      final text = (m.group(2) ?? '').trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// 标签上真正显示的字：`title` 优先，空则退回正文第一个标题，再退回『未命名』。
  String get displayLabel =>
      !isUntitled ? title.trim() : (firstHeading ?? '未命名');

  SpeedNote copyWith({String? title, String? body}) => SpeedNote(
        id: id,
        title: title ?? this.title,
        created: created,
        body: body ?? this.body,
      );

  @override
  String toString() => 'SpeedNote($id, $displayLabel, ${body.length} 字)';
}

/// 一条速记的 id：`sn-` + 日期 + 四位随机尾巴（与主线 id 同一套写法——日期便于人读，
/// 尾巴防撞）。
///
/// [taken] 用来避开已经用掉的 id；撞满 64 次退回微秒时间戳（理论上到不了）。
String newSpeedNoteId(DateTime now, Set<String> taken) {
  final day = '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}';
  final rnd = Random();
  for (var i = 0; i < 64; i++) {
    final tail = rnd.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    final id = 'sn-$day-$tail';
    if (!taken.contains(id)) return id;
  }
  return 'sn-$day-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
}
