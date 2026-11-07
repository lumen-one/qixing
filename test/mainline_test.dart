import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/mainline_service.dart';
import 'package:qixing/domain/mainline.dart';
import 'package:qixing/repository/markdown_mainline_codec.dart';
import 'package:qixing/repository/memory_mainline_repository.dart';

/// 主线（§6.9 / 附录 B.6）：格式往返 + 命令语义。
void main() {
  group('MarkdownMainlineCodec', () {
    const sample = '''---
id: ml-20261018-aaaa
title: 论文冲刺
created: 2026-10-18T09:00
owner: me
---

### 行为链

- [ ] 列提纲
- [x] 写第三章 完成 2026-10-19,21:30 备注：卡了两小时，后来用番茄钟推过去
- [x] 通读一遍

### 记录

- 2026-10-19 ~ 2026-10-21 连续三天都在写第三章
- 2026-10-23
''';

    test('解析人工写的文件：步骤、完成时刻、备注、单日/跨日记录段', () {
      final result = MarkdownMainlineCodec().decode(sample);
      expect(result.warnings, isEmpty);
      expect(result.mainlines, hasLength(1));
      final m = result.mainlines.single;
      expect(m.id, 'ml-20261018-aaaa');
      expect(m.title, '论文冲刺');
      expect(m.created, DateTime(2026, 10, 18, 9));
      expect(m.isActive, isTrue);
      expect(m.steps, hasLength(3));
      expect(m.steps[0].done, isFalse);
      expect(m.steps[1].done, isTrue);
      expect(m.steps[1].doneAt, DateTime(2026, 10, 19, 21, 30));
      expect(m.steps[1].note, '卡了两小时，后来用番茄钟推过去');
      expect(m.steps[2].done, isTrue);
      expect(m.steps[2].doneAt, isNull); // 手勾但没写时刻
      expect(m.doneSteps, 2);
      expect(m.isAllDone, isFalse);
      expect(m.nextStepIndex, 0);
      expect(m.logs, hasLength(2));
      expect(m.logs[0].start, DateTime(2026, 10, 19));
      expect(m.logs[0].end, DateTime(2026, 10, 21));
      expect(m.logs[0].dayCount, 3);
      expect(m.logs[1].text, isEmpty);
      expect(m.logs[1].dayCount, 1);
    });

    test('往返：未知 frontmatter 字段保留，正文按模型重写', () {
      final codec = MarkdownMainlineCodec();
      final first = codec.decode(sample).mainlines.single;
      final encoded = codec.encode([first], originalRaw: sample);
      expect(encoded, contains('owner: me'));
      expect(encoded.contains('completed:'), isFalse);
      final again = codec.decode(encoded).mainlines.single;
      expect(again.title, first.title);
      expect(again.steps.length, first.steps.length);
      expect(again.steps[1].note, first.steps[1].note);
      expect(again.logs[0].end, first.logs[0].end);
    });

    test('归档：completed 有值、排序在跑的在前', () {
      final codec = MarkdownMainlineCodec();
      final a = Mainline(
        id: 'ml-a',
        title: '旧主线',
        created: DateTime(2026, 9, 1),
        completedAt: DateTime(2026, 9, 30, 18),
      );
      final b = Mainline(
        id: 'ml-b',
        title: '当前主线',
        created: DateTime(2026, 10, 1),
      );
      final raw = codec.encode([b, a]);
      final decoded = codec.decode(raw);
      expect(decoded.mainlines.map((m) => m.id), ['ml-b', 'ml-a']);
      expect(decoded.mainlines.last.completedAt, DateTime(2026, 9, 30, 18));
      expect(decoded.mainlines.last.isActive, isFalse);
    });

    test('废弃：abandoned 一行、徽标是废弃、往返不丢', () {
      final codec = MarkdownMainlineCodec();
      final m = Mainline(
        id: 'ml-x',
        title: '放弃的方向',
        created: DateTime(2026, 9, 1),
        abandonedAt: DateTime(2026, 10, 2, 20, 30),
      );
      final raw = codec.encode([m]);
      expect(raw, contains('abandoned: 2026-10-02T20:30'));
      expect(raw.contains('completed:'), isFalse);

      final again = codec.decode(raw).mainlines.single;
      expect(again.abandonedAt, DateTime(2026, 10, 2, 20, 30));
      expect(again.isActive, isFalse);
      expect(again.isAbandoned, isTrue);
      expect(again.isCompleted, isFalse);
      expect(again.archiveLabel, '已废弃');
      expect(again.archivedAt, DateTime(2026, 10, 2, 20, 30));
    });

    test('两个归档时刻都有值（手改边角）：按完成算', () {
      final m = Mainline(
        id: 'ml-y',
        title: '两条都有',
        created: DateTime(2026, 9, 1),
        completedAt: DateTime(2026, 9, 20),
        abandonedAt: DateTime(2026, 9, 21),
      );
      expect(m.isAbandoned, isFalse);
      expect(m.archiveLabel, '已完成');
      expect(m.archivedAt, DateTime(2026, 9, 20));
    });

    test('月记：一条一行，手写重复行以后者为准，往返不丢', () {
      const raw = '''---
id: ml-m
title: 论文
created: 2026-10-01T09:00
---

### 行为链

- [ ] 列提纲

### 记录

- 2026-10-19 单天一条

### 月记

- 2026-10 这个月在写第三章
- 2026-09 九月在找资料
- 2026-10 十月改口了
''';
      final codec = MarkdownMainlineCodec();
      final m = codec.decode(raw).mainlines.single;
      expect(m.months, hasLength(2), reason: '同一个月只留一条');
      expect(m.monthNoteOf(2026, 10)?.text, '十月改口了');
      expect(m.monthsInOrder.map((n) => n.month), [9, 10]);
      // 月记不落进记录段：它不覆盖任何一天
      expect(m.logs, hasLength(1));

      final encoded = codec.encode([m]);
      expect(encoded, contains('### 月记'));
      expect(encoded, contains('- 2026-10 十月改口了'));
      expect(codec.decode(encoded).mainlines.single.months, hasLength(2));
    });

    test('没有月记：保存后不留 `### 月记` 空段', () {
      final codec = MarkdownMainlineCodec();
      final m = codec.decode(sample).mainlines.single;
      expect(codec.encode([m]), isNot(contains('### 月记')));
    });

    test('宽容：缺 id / 未闭合 frontmatter 不抛异常', () {
      final codec = MarkdownMainlineCodec();
      final result = codec.decode('''
---
title: 没有 id
created: 2026-10-01T09:00
---

- [ ] x

---
id: ml-half
title: 没闭合
''');
      expect(result.mainlines, isEmpty);
      expect(result.warnings, isNotEmpty);
    });
  });

  group('MainlineLog', () {
    test('含两端：端点相接算重叠，隔一天不算', () {
      final a = MainlineLog.range(
          start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 5));
      bool hit(int from, int to) => a.overlaps(MainlineLog.range(
          start: DateTime(2026, 10, from), end: DateTime(2026, 10, to)));
      expect(hit(5, 8), isTrue, reason: '端点相接共用一天');
      expect(hit(6, 8), isFalse);
      expect(hit(1, 1), isFalse);
      expect(hit(1, 2), isTrue);
      expect(hit(3, 4), isTrue, reason: '被包含');
      expect(hit(1, 9), isTrue, reason: '整个包住');
    });
  });

  group('MainlineService', () {
    test('创建 → 勾选记时刻 → 取消清时刻', () async {
      final now = DateTime(2026, 10, 21, 9);
      final repo = MemoryMainlineRepository();
      final svc = MainlineService(repo: repo, clock: () => now);
      final m = await svc.create(title: '论文', steps: ['列提纲', '写第三章']);
      expect(svc.active?.id, m.id);
      expect(svc.mainlines, hasLength(1));
      expect(svc.mainlines.single.steps, hasLength(2));

      await svc.toggleStep(m.id, 1, done: true);
      expect(svc.byId(m.id)!.steps[1].doneAt, now);
      expect(svc.byId(m.id)!.progressText, '1/2');

      await svc.toggleStep(m.id, 1, done: false);
      expect(svc.byId(m.id)!.steps[1].done, isFalse);
      expect(svc.byId(m.id)!.steps[1].doneAt, isNull);
    });

    test('归档必须全勾完；归档后 active 为空、数据仍在', () async {
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => DateTime(2026, 10, 21, 18, 0),
      );
      final m = await svc.create(title: '论文', steps: ['a', 'b']);
      await expectLater(svc.complete(m.id), throwsStateError);

      await svc.toggleStep(m.id, 0, done: true);
      await svc.toggleStep(m.id, 1, done: true);
      await svc.complete(m.id);

      expect(svc.active, isNull);
      expect(svc.archived, hasLength(1));
      expect(svc.byId(m.id)!.completedAt, DateTime(2026, 10, 21, 18));
      expect(svc.byId(m.id)!.steps, hasLength(2));
    });

    test('空链不算勾完（不能凭空归档）', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '空主线');
      expect(svc.byId(m.id)!.isAllDone, isFalse);
      await expectLater(svc.complete(m.id), throwsStateError);
    });

    test('废弃不要求勾完：active 空、不写完成时刻、数据仍在', () async {
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => DateTime(2026, 10, 21, 20, 30),
      );
      final m = await svc.create(title: '论文', steps: ['a', 'b']);
      await svc.toggleStep(m.id, 0, done: true);

      await svc.abandon(m.id);
      final after = svc.byId(m.id)!;
      expect(after.isActive, isFalse);
      expect(after.isAbandoned, isTrue);
      expect(after.completedAt, isNull);
      expect(after.abandonedAt, DateTime(2026, 10, 21, 20, 30));
      expect(after.steps, hasLength(2));
      expect(svc.active, isNull);
      expect(svc.archived, hasLength(1));
    });

    test('已归档的不能再废弃 / 再完成', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文', steps: ['a']);
      await svc.abandon(m.id);
      await svc.abandon(m.id);
      await svc.complete(m.id); // 全勾完也不行：已经不在跑了
      final after = svc.byId(m.id)!;
      expect(after.completedAt, isNull);
      expect(after.abandonedAt, isNotNull);
    });

    test('整链重写保留完成状态（拖动排序不把勾掉的状态丢掉）', () async {
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => DateTime(2026, 10, 21, 9),
      );
      final m = await svc.create(title: '论文', steps: ['a', 'b', 'c']);
      await svc.toggleStep(m.id, 0, done: true);

      final steps = svc.byId(m.id)!.steps;
      await svc.setSteps(m.id, [steps[2], steps[0], steps[1]]);
      final after = svc.byId(m.id)!;
      expect(after.steps.map((s) => s.title), ['c', 'a', 'b']);
      expect(after.steps[1].done, isTrue);
      expect(after.steps[1].doneAt, DateTime(2026, 10, 21, 9));
    });

    test('记录：加 / 改 / 删；起止写反自动对调', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 19), text: '三天');
      final log = svc.byId(m.id)!.logs.single;
      expect(log.start, DateTime(2026, 10, 19));
      expect(log.end, DateTime(2026, 10, 21));

      await svc.updateLog(m.id, MainlineLogRef.of(log), text: '改过');
      expect(svc.byId(m.id)!.logs.single.text, '改过');

      await svc.removeLog(
          m.id, MainlineLogRef.of(svc.byId(m.id)!.logs.single));
      expect(svc.byId(m.id)!.logs, isEmpty);
    });

    test('记录段互不重叠：相交 / 被包含 / 端点相接都拒绝，且不落盘', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 10),
          end: DateTime(2026, 10, 15),
          text: '写第三章');

      Future<void> add(int from, int to) => svc.addLog(m.id,
          start: DateTime(2026, 10, from),
          end: DateTime(2026, 10, to),
          text: '撞一段');

      await expectLater(add(8, 11), throwsStateError);
      await expectLater(add(12, 13), throwsStateError);
      await expectLater(add(14, 20), throwsStateError);
      await expectLater(add(15, 18), throwsStateError);
      await expectLater(add(10, 15), throwsStateError);
      expect(svc.byId(m.id)!.logs, hasLength(1), reason: '拒绝的不落盘');

      await add(16, 18);
      expect(svc.byId(m.id)!.logsInOrder.map((l) => l.text),
          ['写第三章', '撞一段']);
    });

    test('起止写反按归一后的区间校验；删掉之后空档可再用', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 10),
          end: DateTime(2026, 10, 12),
          text: 'A');
      await expectLater(
          svc.addLog(m.id,
              start: DateTime(2026, 10, 13),
              end: DateTime(2026, 10, 11),
              text: 'B'),
          throwsStateError);

      await svc.removeLog(m.id, MainlineLogRef.of(svc.byId(m.id)!.logs.single));
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 11), end: DateTime(2026, 10, 13), text: 'B');
      expect(svc.byId(m.id)!.logs.single.text, 'B');
    });

    test('改记录：只改文字不验；改起止撞到别人拒绝，改到空档放行', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 4), text: 'A');
      await svc.addLog(m.id,
          start: DateTime(2026, 10, 10), end: DateTime(2026, 10, 12), text: 'B');
      final a = svc.byId(m.id)!.logs.firstWhere((l) => l.text == 'A');

      await svc.updateLog(m.id, MainlineLogRef.of(a), text: 'A 改过');
      final a2 = svc.byId(m.id)!.logs.firstWhere((l) => l.text == 'A 改过');
      expect(a2.start, DateTime(2026, 10, 2));

      await expectLater(
          svc.updateLog(m.id, MainlineLogRef.of(a2),
              start: DateTime(2026, 10, 11)),
          throwsStateError);
      expect(svc.byId(m.id)!.logs.firstWhere((l) => l.text == 'A 改过').start,
          DateTime(2026, 10, 2),
          reason: '拒绝的改动不落盘');

      await svc.updateLog(m.id, MainlineLogRef.of(a2),
          start: DateTime(2026, 10, 5), end: DateTime(2026, 10, 8));
      final moved = svc.byId(m.id)!.logs.firstWhere((l) => l.text == 'A 改过');
      expect(moved.start, DateTime(2026, 10, 5));
      expect(moved.end, DateTime(2026, 10, 8));
    });

    test('记录按内容定位：另一份引擎插了一条更早的记录也不会改错', () async {
      final repo = MemoryMainlineRepository();
      final mine = MainlineService(repo: repo);
      final m = await mine.create(title: '论文');
      await mine.addLog(m.id,
          start: DateTime(2026, 10, 19),
          end: DateTime(2026, 10, 21),
          text: '写第三章');
      final ref = MainlineLogRef.of(mine.byId(m.id)!.logs.single);

      // 另一个引擎（同一份盘）在这中间插了一条起始日更早的：排序后同一个下标
      // 就不再指原来那条了。
      final other = MainlineService(repo: repo);
      await other.load();
      await other.addLog(m.id,
          start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 2), text: '九月');

      await mine.updateLog(m.id, ref, text: '改过');
      final logs = mine.byId(m.id)!.logs;
      expect(logs.firstWhere((l) => l.text == '改过').start,
          DateTime(2026, 10, 19));
      expect(logs.firstWhere((l) => l.text == '九月').start,
          DateTime(2026, 9, 1),
          reason: '别人那条不能动');
      expect(logs.any((l) => l.text == '写第三章'), isFalse);

      // 那条已经不在了：改要报错（不猜），删是幂等的（目的已达成）
      await expectLater(
          mine.updateLog(m.id, ref, text: '再来'), throwsStateError);
      await mine.removeLog(m.id, ref);
      expect(mine.byId(m.id)!.logs, hasLength(2));
    });

    test('月记：一个月一条，再写就是改；空文本删掉这条', () async {
      final svc = MainlineService(repo: MemoryMainlineRepository());
      final m = await svc.create(title: '论文');

      await svc.setMonthNote(m.id, 2026, 10, '这个月在写第三章');
      await svc.setMonthNote(m.id, 2026, 10, '改过');
      expect(svc.byId(m.id)!.months, hasLength(1));
      expect(svc.byId(m.id)!.monthNoteOf(2026, 10)!.text, '改过');

      await svc.setMonthNote(m.id, 2026, 9, '九月在找资料');
      expect(svc.byId(m.id)!.monthsInOrder.map((n) => n.month), [9, 10]);

      await svc.setMonthNote(m.id, 2026, 10, '   ');
      expect(svc.byId(m.id)!.months, hasLength(1));
      expect(svc.byId(m.id)!.monthNoteOf(2026, 10), isNull);
    });

    test('落盘 → 新实例读回（仓储是唯一事实来源）', () async {      final repo = MemoryMainlineRepository();
      final one = MainlineService(repo: repo);
      final m = await one.create(title: '论文', steps: ['a']);
      await one.addLog(m.id,
          start: DateTime(2026, 10, 19), end: DateTime(2026, 10, 20), text: '写');

      final two = MainlineService(repo: repo);
      await two.load();
      expect(two.active?.title, '论文');
      expect(two.active?.logs.single.text, '写');
    });

    test('归档列表：完成与废弃混排，按归档时刻从新到旧', () async {
      var now = DateTime(2026, 10, 1, 9);
      final svc = MainlineService(
        repo: MemoryMainlineRepository(),
        clock: () => now,
      );
      final a = await svc.create(title: 'A', steps: ['x']);
      await svc.toggleStep(a.id, 0, done: true);
      await svc.complete(a.id);

      now = DateTime(2026, 10, 5, 9);
      final b = await svc.create(title: 'B', steps: ['y']);
      await svc.abandon(b.id);

      now = DateTime(2026, 10, 9, 9);
      final c = await svc.create(title: 'C', steps: ['z']);
      await svc.toggleStep(c.id, 0, done: true);
      await svc.complete(c.id);

      expect(svc.archived.map((m) => m.title), ['C', 'B', 'A']);
      expect(svc.archived.map((m) => m.archiveLabel), ['已完成', '已废弃', '已完成']);
      expect(svc.active, isNull);
    });
  });
}
