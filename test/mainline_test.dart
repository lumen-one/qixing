import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/mainline_service.dart';
import 'package:qixing/domain/mainline.dart';
import 'package:qixing/repository/markdown_mainline_codec.dart';
import 'package:qixing/repository/memory_mainline_repository.dart';

/// 主线（§6.9 / formats/mainline.md B.6）：格式往返 + 命令语义。
///
/// 记录与月记不在这份文件里，它们的测试在 `logbook_test.dart`。
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
''';

    test('解析人工写的文件：步骤、完成时刻、备注', () {
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
    });

    test('旧版的记录段与月记：不再读，读盘给一条告警，保存后消失', () {
      const legacy = '''---
id: ml-old
title: 老文件
created: 2026-10-01T09:00
---

### 行为链

- [ ] 走一步

### 记录

- 2026-10-19 ~ 2026-10-21 三天都在写

### 月记

- 2026-10 十月在写第三章
''';
      final codec = MarkdownMainlineCodec();
      final result = codec.decode(legacy);
      expect(result.mainlines.single.steps.single.title, '走一步');
      expect(result.warnings.single, contains('记录.md'));

      final encoded = codec.encode(result.mainlines, originalRaw: legacy);
      expect(encoded.contains('### 记录'), isFalse);
      expect(encoded.contains('三天都在写'), isFalse);
      expect(encoded.contains('### 月记'), isFalse);
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

    test('落盘 → 新实例读回（仓储是唯一事实来源）', () async {
      final repo = MemoryMainlineRepository();
      final one = MainlineService(repo: repo);
      await one.create(title: '论文', steps: ['a']);

      final two = MainlineService(repo: repo);
      await two.load();
      expect(two.active?.title, '论文');
      expect(two.active?.steps.single.title, 'a');
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
