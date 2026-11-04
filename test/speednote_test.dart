import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/notes_markdown.dart';
import 'package:qixing/application/speednote_service.dart';
import 'package:qixing/domain/speednote.dart';
import 'package:qixing/repository/markdown_speednote_codec.dart';
import 'package:qixing/repository/memory_speednote_repository.dart';
import 'package:qixing/repository/speednote_repository.dart';

/// 速记（§6.13 / 附录 B.9）：格式往返 + 命令语义 + 标题扫描。
void main() {
  const sample = '---\n'
      'id: sn-20261104-3f9c\n'
      'title: 十一月\n'
      'created: 2026-11-04T16:20\n'
      '---\n'
      '\n'
      '# 本周\n'
      '\n'
      '- 侧边栏把手\n'
      '\n'
      '---\n'
      '\n'
      '上面这行是水平分割线，不是下一条速记。\n'
      '\n'
      '---\n'
      'id: sn-20261105-7a01\n'
      'title:\n'
      'created: 2026-11-05T09:02\n'
      '---\n'
      '\n'
      '还没想好写什么。\n';

  group('MarkdownSpeedNoteCodec', () {
    test('解析：两条速记、正文里的水平分割线留在原文里', () {
      final result = MarkdownSpeedNoteCodec().decode(sample);
      expect(result.warnings, isEmpty);
      expect(result.notes, hasLength(2));

      final first = result.notes.first;
      expect(first.id, 'sn-20261104-3f9c');
      expect(first.title, '十一月');
      expect(first.created, DateTime(2026, 11, 4, 16, 20));
      expect(first.body, '# 本周\n\n- 侧边栏把手\n\n---\n\n上面这行是水平分割线，不是下一条速记。');

      final second = result.notes[1];
      expect(second.id, 'sn-20261105-7a01');
      expect(second.isUntitled, isTrue);
      expect(second.body, '还没想好写什么。');
    });

    test('缺 id 的块跳过并记告警', () {
      final result = MarkdownSpeedNoteCodec().decode(
        '---\n'
        'title: 没有 id\n'
        '---\n'
        '\n'
        '正文\n',
      );
      expect(result.notes, isEmpty);
      expect(result.warnings, hasLength(1));
    });

    test('编码往返：正文一字不改，顺序照旧', () {
      final codec = MarkdownSpeedNoteCodec();
      final notes = codec.decode(sample).notes;
      final raw = codec.encode(notes, originalRaw: sample);
      final again = codec.decode(raw).notes;

      expect(again.map((n) => n.id), notes.map((n) => n.id));
      expect(again.map((n) => n.body), notes.map((n) => n.body));
      expect(again.map((n) => n.title), notes.map((n) => n.title));
    });

    test('未知 frontmatter 字段原样保留', () {
      const raw = '---\n'
          'id: sn-1\n'
          'title: 手工加的\n'
          'created: 2026-11-04T08:00\n'
          'pinned: true\n'
          '---\n'
          '\n'
          '正文\n';
      final codec = MarkdownSpeedNoteCodec();
      final notes = codec.decode(raw).notes;
      final out = codec.encode([notes.single.copyWith(title: '改了名')],
          originalRaw: raw);
      expect(out, contains('pinned: true'));
      expect(out, contains('title: 改了名'));
    });

    test('空标题编码成 `title:`，再读回来仍是空', () {
      final codec = MarkdownSpeedNoteCodec();
      final out = codec.encode([
        SpeedNote(id: 'sn-2', created: DateTime(2026, 11, 4), body: 'x'),
      ]);
      expect(out, contains('title:\n'));
      expect(codec.decode(out).notes.single.title, isEmpty);
    });
  });

  group('标签名', () {
    test('title 为空时退回正文第一个标题，再退回『未命名』', () {
      final withHeading = SpeedNote(
        id: 'a',
        created: _epoch,
        body: '开场白\n\n# 十一月的计划\n\n正文',
      );
      expect(withHeading.displayLabel, '十一月的计划');

      final blank = SpeedNote(id: 'b', created: _epoch, body: '只有正文');
      expect(blank.displayLabel, '未命名');
      expect(blank.tabLabel, '未命名');
    });

    test('显式标题优先于正文标题', () {
      final note = SpeedNote(
        id: 'c',
        title: '手动命的名',
        created: _epoch,
        body: '# 正文标题',
      );
      expect(note.displayLabel, '手动命的名');
    });
  });

  group('scanNotesHeadings', () {
    test('层级与行号', () {
      const lines = ['# 一', '正文', '## 二', '### 三', '#### 四'];
      final headings = scanNotesHeadings(lines);
      expect(headings.map((h) => h.level), [1, 2, 3, 4]);
      expect(headings.map((h) => h.line), [0, 2, 3, 4]);
    });

    test('围栏代码块里的 # 不算标题', () {
      const lines = ['# 真标题', '```', '# 这不是标题', '```', '## 又一个'];
      final headings = scanNotesHeadings(lines);
      expect(headings.map((h) => h.text), ['真标题', '又一个']);
    });
  });

  group('SpeedNoteService', () {
    test('新建追加到末尾', () async {
      final repo = MemorySpeedNoteRepository([
        SpeedNote(id: 'a', created: _epoch, body: '1'),
        SpeedNote(id: 'b', created: _epoch, body: '2'),
      ]);
      final svc = SpeedNoteService(repo: repo);
      await svc.load();
      final note = await svc.create(now: DateTime(2026, 11, 4, 16, 20));
      expect(svc.notes.map((n) => n.id), ['a', 'b', note.id]);
      expect(note.id, startsWith('sn-20261104-'));
    });

    test('改正文不动别人的顺位', () async {
      final repo = MemorySpeedNoteRepository([
        SpeedNote(id: 'a', created: _epoch, body: '1'),
        SpeedNote(id: 'b', created: _epoch, body: '2'),
      ]);
      final svc = SpeedNoteService(repo: repo);
      await svc.load();
      await svc.saveBody('b', '2 改了');
      expect(svc.notes.map((n) => n.id), ['a', 'b']);
      expect(svc.byId('b')!.body, '2 改了');
    });

    test('内容没变就不写盘', () async {
      final repo = _CountingRepository([
        SpeedNote(id: 'a', created: _epoch, body: '1'),
      ]);
      final svc = SpeedNoteService(repo: repo);
      await svc.load();
      await svc.saveBody('a', '1');
      expect(repo.saves, 0);
      await svc.saveBody('a', '2');
      expect(repo.saves, 1);
    });

    test('删除后按原位置撤销回来', () async {
      final repo = MemorySpeedNoteRepository([
        SpeedNote(id: 'a', created: _epoch, body: '1'),
        SpeedNote(id: 'b', created: _epoch, body: '2'),
        SpeedNote(id: 'c', created: _epoch, body: '3'),
      ]);
      final svc = SpeedNoteService(repo: repo);
      await svc.load();
      final b = svc.byId('b')!;
      await svc.delete('b');
      expect(svc.notes.map((n) => n.id), ['a', 'c']);
      await svc.restore(b, index: 1);
      expect(svc.notes.map((n) => n.id), ['a', 'b', 'c']);
    });

    test('改名去掉换行与首尾空白', () async {
      final repo = MemorySpeedNoteRepository([
        SpeedNote(id: 'a', created: _epoch),
      ]);
      final svc = SpeedNoteService(repo: repo);
      await svc.load();
      await svc.rename('a', '  十一月\n计划  ');
      expect(svc.byId('a')!.title, '十一月 计划');
    });
  });
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

class _CountingRepository implements SpeedNoteRepository {
  _CountingRepository(this._notes);

  List<SpeedNote> _notes;
  int saves = 0;

  @override
  List<String> get warnings => const [];

  @override
  Future<List<SpeedNote>> loadAll() async => _notes;

  @override
  Future<void> saveAll(List<SpeedNote> notes) async {
    saves++;
    _notes = notes;
  }
}
