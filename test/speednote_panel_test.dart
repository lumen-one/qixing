import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/speednote_service.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/speednote.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_speednote_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/speednote_panel.dart';
import 'package:qixing/ui/widgets/notes_blocks.dart';

/// 速记覆盖页（§6.13）：标签栏、折叠、新建、删除。
void main() {
  final epoch = DateTime(2026, 11, 4, 16);

  AppController makeController(List<SpeedNote> notes) {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 11, 4, 9),
    );
    return AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      speedNoteService:
          SpeedNoteService(repo: MemorySpeedNoteRepository(notes)),
    );
  }

  Future<void> pumpOverlay(WidgetTester tester, AppController c) async {
    await c.refreshSpeedNotes();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 620,
          child: SpeedNoteOverlay(controller: c, onClose: () async {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 正文里的标题（目录条上也有同名文字，那不是折叠头）。
  Finder heading(String text) => find.descendant(
        of: find.byType(NotesBlockView),
        matching: find.text(text),
      );

  List<SpeedNote> twoNotes() => [
        SpeedNote(
          id: 'a',
          title: '甲',
          created: epoch,
          body: '# 一\n\n- 第一项\n\n## 二\n\n- 第二项',
        ),
        SpeedNote(
          id: 'b',
          title: '乙',
          created: epoch,
          body: '第二条正文',
        ),
      ];

  testWidgets('标签栏摆出全部速记，计数是总条数', (tester) async {
    final c = makeController(twoNotes());
    await pumpOverlay(tester, c);

    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
  });

  testWidgets('点标签换一条', (tester) async {
    final c = makeController(twoNotes());
    await pumpOverlay(tester, c);

    expect(find.text('第一项'), findsOneWidget);
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();

    expect(find.text('第一项'), findsNothing);
    expect(find.text('第二条正文'), findsOneWidget);
  });

  testWidgets('点标题收起这一节，再点展开', (tester) async {
    final c = makeController(twoNotes());
    await pumpOverlay(tester, c);

    // 一级标题收起时连它下面的二级标题一起收。
    await tester.tap(heading('一'));
    await tester.pumpAndSettle();
    expect(find.text('第一项'), findsNothing);
    expect(find.text('第二项'), findsNothing);

    await tester.tap(heading('一'));
    await tester.pumpAndSettle();
    expect(find.text('第一项'), findsOneWidget);

    // 只收二级，一级下面的正文还在。
    await tester.tap(heading('二'));
    await tester.pumpAndSettle();
    expect(find.text('第一项'), findsOneWidget);
    expect(find.text('第二项'), findsNothing);
  });

  testWidgets('加号新建一条并直接进编辑态', (tester) async {
    final c = makeController(twoNotes());
    await pumpOverlay(tester, c);

    await tester.tap(find.byTooltip('新建速记'));
    await tester.pumpAndSettle();

    expect(find.text('3 条'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(c.speedNotes, hasLength(3));
    expect(c.speedNoteTabId, c.speedNotes.last.id);
  });

  testWidgets('✕ 删掉当前这条，标签栏跟着少一条', (tester) async {
    final c = makeController(twoNotes());
    await pumpOverlay(tester, c);

    await tester.tap(find.byTooltip('删除这条速记'));
    await tester.pumpAndSettle();

    expect(find.text('1 条'), findsOneWidget);
    expect(find.text('甲'), findsNothing);
    expect(c.speedNotes.single.id, 'b');
    // 撤销入口在 toast 里
    expect(find.text('撤销'), findsOneWidget);
  });
}
