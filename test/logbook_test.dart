import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/logbook_service.dart';
import 'package:qixing/domain/logbook.dart';
import 'package:qixing/repository/markdown_logbook_codec.dart';
import 'package:qixing/repository/memory_logbook_repository.dart';

/// 记录册（panels/record.md / formats/logbook.md B.10）：格式往返 + 命令语义。
///
/// 与主线是两份互不相干的数据：这里没有一条命令要主线 id。
void main() {
  group('MarkdownLogBookCodec', () {
    const sample = '''### 记录

- 2026-10-19 ~ 2026-10-21 连续三天都在写第三章
- 2026-10-23

### 月记

- 2026-10 这个月在写第三章
- 2026-09 九月在找资料
- 2026-10 十月改口了
''';

    test('解析人工写的文件：单日 / 跨日记录段、月记去重', () {
      final result = MarkdownLogBookCodec().decode(sample);
      expect(result.warnings, isEmpty);
      final book = result.book;
      expect(book.segments, hasLength(2));
      expect(book.segments[0].start, DateTime(2026, 10, 19));
      expect(book.segments[0].end, DateTime(2026, 10, 21));
      expect(book.segments[0].dayCount, 3);
      expect(book.segments[1].text, isEmpty);
      expect(book.segments[1].dayCount, 1);

      expect(book.months, hasLength(2), reason: '同一个月只留一条');
      expect(book.monthNoteOf(2026, 10)?.text, '十月改口了');
      expect(book.monthsInOrder.map((n) => n.month), [9, 10]);
    });

    test('往返：写回再读回，两段都还在', () {
      final codec = MarkdownLogBookCodec();
      final book = codec.decode(sample).book;
      final encoded = codec.encode(book);
      expect(encoded, contains('### 记录'));
      expect(encoded, contains('### 月记'));
      expect(encoded, contains('- 2026-10-19 ~ 2026-10-21 连续三天都在写第三章'));

      final again = codec.decode(encoded).book;
      expect(again.segments, hasLength(2));
      expect(again.segments[0].end, DateTime(2026, 10, 21));
      expect(again.months, hasLength(2));
    });

    test('没有月记：保存后不留 `### 月记` 空段；空册子只有 `### 记录`', () {
      final codec = MarkdownLogBookCodec();
      final only = LogBook(segments: [
        LogSegment.range(
            start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 3), text: '两天'),
      ]);
      final encoded = codec.encode(only);
      expect(encoded.contains('### 月记'), isFalse);

      final empty = codec.encode(LogBook());
      expect(empty.contains('### 记录'), isTrue);
      expect(empty.contains('### 月记'), isFalse);
    });

    test('读不出任何一段时给一条告警（段标题被改坏了）', () {
      final result = MarkdownLogBookCodec().decode('随便写点东西\n- 2026-10-19 没有段标题\n');
      expect(result.book.segments, isEmpty);
      expect(result.warnings.single, contains('记录.md'));
    });

    test('空文件：一条都没有，也不告警', () {
      final result = MarkdownLogBookCodec().decode('');
      expect(result.book.segments, isEmpty);
      expect(result.book.months, isEmpty);
      expect(result.warnings, isEmpty);
    });
  });

  group('LogSegment', () {
    test('含两端：端点相接算重叠，隔一天不算', () {
      final a = LogSegment.range(
          start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 5));
      bool hit(int from, int to) => a.overlaps(LogSegment.range(
          start: DateTime(2026, 10, from), end: DateTime(2026, 10, to)));
      expect(hit(5, 8), isTrue, reason: '端点相接共用一天');
      expect(hit(6, 8), isFalse);
      expect(hit(1, 1), isFalse);
      expect(hit(1, 2), isTrue);
      expect(hit(3, 4), isTrue, reason: '被包含');
      expect(hit(1, 9), isTrue, reason: '整个包住');
    });
  });

  group('LogBookService', () {
    test('加 / 改 / 删；起止写反自动对调', () async {
      final svc = LogBookService(repo: MemoryLogBookRepository());
      await svc.add(
          start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 19), text: '三天');
      final log = svc.book.segments.single;
      expect(log.start, DateTime(2026, 10, 19));
      expect(log.end, DateTime(2026, 10, 21));

      await svc.update(LogSegmentRef.of(log), text: '改过');
      expect(svc.book.segments.single.text, '改过');

      await svc.remove(LogSegmentRef.of(svc.book.segments.single));
      expect(svc.book.segments, isEmpty);
    });

    test('记录段互不重叠：相交 / 被包含 / 端点相接都拒绝，且不落盘', () async {
      final svc = LogBookService(repo: MemoryLogBookRepository());
      await svc.add(
          start: DateTime(2026, 10, 10),
          end: DateTime(2026, 10, 15),
          text: '写第三章');

      Future<void> add(int from, int to) => svc.add(
          start: DateTime(2026, 10, from),
          end: DateTime(2026, 10, to),
          text: '撞一段');

      await expectLater(add(8, 11), throwsStateError);
      await expectLater(add(12, 13), throwsStateError);
      await expectLater(add(14, 20), throwsStateError);
      await expectLater(add(15, 18), throwsStateError);
      await expectLater(add(10, 15), throwsStateError);
      expect(svc.book.segments, hasLength(1), reason: '拒绝的不落盘');

      await add(16, 18);
      expect(svc.book.segmentsInOrder.map((l) => l.text), ['写第三章', '撞一段']);
    });

    test('起止写反按归一后的区间校验；删掉之后空档可再用', () async {
      final svc = LogBookService(repo: MemoryLogBookRepository());
      await svc.add(
          start: DateTime(2026, 10, 10), end: DateTime(2026, 10, 12), text: 'A');
      await expectLater(
          svc.add(
              start: DateTime(2026, 10, 13),
              end: DateTime(2026, 10, 11),
              text: 'B'),
          throwsStateError);

      await svc.remove(LogSegmentRef.of(svc.book.segments.single));
      await svc.add(
          start: DateTime(2026, 10, 11), end: DateTime(2026, 10, 13), text: 'B');
      expect(svc.book.segments.single.text, 'B');
    });

    test('改记录：只改文字不验；改起止撞到别人拒绝，改到空档放行', () async {
      final svc = LogBookService(repo: MemoryLogBookRepository());
      await svc.add(
          start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 4), text: 'A');
      await svc.add(
          start: DateTime(2026, 10, 10), end: DateTime(2026, 10, 12), text: 'B');
      final a = svc.book.segments.firstWhere((l) => l.text == 'A');

      await svc.update(LogSegmentRef.of(a), text: 'A 改过');
      final a2 = svc.book.segments.firstWhere((l) => l.text == 'A 改过');
      expect(a2.start, DateTime(2026, 10, 2));

      await expectLater(
          svc.update(LogSegmentRef.of(a2), start: DateTime(2026, 10, 11)),
          throwsStateError);
      expect(
          svc.book.segments.firstWhere((l) => l.text == 'A 改过').start,
          DateTime(2026, 10, 2),
          reason: '拒绝的改动不落盘');

      await svc.update(LogSegmentRef.of(a2),
          start: DateTime(2026, 10, 5), end: DateTime(2026, 10, 8));
      final moved = svc.book.segments.firstWhere((l) => l.text == 'A 改过');
      expect(moved.start, DateTime(2026, 10, 5));
      expect(moved.end, DateTime(2026, 10, 8));
    });

    test('按内容定位：另一份引擎插了一条更早的记录也不会改错', () async {
      final repo = MemoryLogBookRepository();
      final mine = LogBookService(repo: repo);
      await mine.add(
          start: DateTime(2026, 10, 19),
          end: DateTime(2026, 10, 21),
          text: '写第三章');
      final ref = LogSegmentRef.of(mine.book.segments.single);

      // 另一个引擎（同一份盘）在这中间插了一条起始日更早的：排序后同一个下标
      // 就不再指原来那条了。
      final other = LogBookService(repo: repo);
      await other.load();
      await other.add(
          start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 2), text: '九月');

      await mine.update(ref, text: '改过');
      final segments = mine.book.segments;
      expect(segments.firstWhere((l) => l.text == '改过').start,
          DateTime(2026, 10, 19));
      expect(segments.firstWhere((l) => l.text == '九月').start,
          DateTime(2026, 9, 1),
          reason: '别人那条不能动');
      expect(segments.any((l) => l.text == '写第三章'), isFalse);

      // 那条已经不在了：改要报错（不猜），删是幂等的（目的已达成）
      await expectLater(mine.update(ref, text: '再来'), throwsStateError);
      await mine.remove(ref);
      expect(mine.book.segments, hasLength(2));
    });

    test('月记：一个月一条，再写就是改；空文本删掉这条', () async {
      final svc = LogBookService(repo: MemoryLogBookRepository());

      await svc.setMonthNote(2026, 10, '这个月在写第三章');
      await svc.setMonthNote(2026, 10, '改过');
      expect(svc.book.months, hasLength(1));
      expect(svc.book.monthNoteOf(2026, 10)!.text, '改过');

      await svc.setMonthNote(2026, 9, '九月在找资料');
      expect(svc.book.monthsInOrder.map((n) => n.month), [9, 10]);

      await svc.setMonthNote(2026, 10, '   ');
      expect(svc.book.months, hasLength(1));
      expect(svc.book.monthNoteOf(2026, 10), isNull);
    });

    test('落盘 → 新实例读回（仓储是唯一事实来源）', () async {
      final repo = MemoryLogBookRepository();
      final one = LogBookService(repo: repo);
      await one.add(
          start: DateTime(2026, 10, 19), end: DateTime(2026, 10, 20), text: '写');
      await one.setMonthNote(2026, 10, '十月');

      final two = LogBookService(repo: repo);
      await two.load();
      expect(two.book.segments.single.text, '写');
      expect(two.book.monthNoteOf(2026, 10)?.text, '十月');
    });
  });
}
