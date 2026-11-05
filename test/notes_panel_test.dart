import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/notes_reader.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/notes_panel.dart';

/// 灵感页的编辑态与面板收起（ui-interaction.md §6.2）：收起只放焦点，不丢草稿。
class _FakeNotesPort implements NotesPort {
  _FakeNotesPort(this.raw);

  String raw;

  @override
  Future<NotesReadResult> read() async => extractNotesSection(raw);

  @override
  Future<NotesWriteStatus> write(String body) async => NotesWriteStatus.ok;
}

void main() {
  AppController makeController() {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 11, 5, 9),
    );
    return AppController(service: tasks, taskDir: '/tmp/tasks')
      ..notesPort = _FakeNotesPort('---\ntitle: 灵感\n---\n第一行\n第二行\n');
  }

  Future<void> pumpPanel(WidgetTester tester, AppController c) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 620,
          child: NotesPanel(controller: c),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('收起面板时放掉焦点，编辑态与草稿都留着', (tester) async {
    final c = makeController();
    await pumpPanel(tester, c);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '写了一半');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);

    // 面板收起的统一出口（悬浮壳与抽屉都调它）。
    await c.closeSpeedNote();
    await tester.pump();

    // 键盘跟着输入法连接走：连接关了，就不会跟到别的页上去。
    expect(tester.testTextInput.hasAnyClients, isFalse);
    // 手工保存的页面：收起不等于取消，草稿还在，也没落盘。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('编辑中'), findsOneWidget);
    expect(c.notes!.bodyLines, contains('第一行'));
  });
}
