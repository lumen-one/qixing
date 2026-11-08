import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/logbook_service.dart';
import 'package:qixing/application/mainline_service.dart';
import 'package:qixing/application/task_service.dart';
import 'package:qixing/domain/logbook.dart';
import 'package:qixing/domain/mainline.dart';
import 'package:qixing/domain/time_context.dart';
import 'package:qixing/repository/memory_logbook_repository.dart';
import 'package:qixing/repository/memory_mainline_repository.dart';
import 'package:qixing/repository/memory_task_repository.dart';
import 'package:qixing/scheduler/slack_scheduler.dart';
import 'package:qixing/ui/app_controller.dart';
import 'package:qixing/ui/panels/mainline_panel.dart';
import 'package:qixing/ui/panels/side_panel.dart';

/// 主线覆盖页（ui-interaction.md §6.9）与记录页（panels/record.md §6.15）。
void main() {
  AppController makeController({
    List<Mainline> prefix = const [],
    List<LogSegment> segments = const [],
    List<MonthNote> months = const [],
  }) {
    final tasks = TaskService(
      repo: MemoryTaskRepository(),
      scheduler: const SlackScheduler(),
      workRule: WorkTimeRule.standard,
      clock: () => DateTime(2026, 10, 21, 9),
    );
    return AppController(
      service: tasks,
      taskDir: '/tmp/tasks',
      mainlineService: MainlineService(
        repo: MemoryMainlineRepository(prefix),
        clock: () => DateTime(2026, 10, 21, 9),
      ),
      logBookService: LogBookService(
        repo: MemoryLogBookRepository(
          LogBook(segments: segments, months: months),
        ),
      ),
    );
  }

  Future<void> boot(WidgetTester tester, AppController controller) async {
    await tester.runAsync(() => controller.mainlineService!.load());
    await tester.runAsync(() => controller.logBookService!.load());
  }

  Future<void> pumpPanel(
    WidgetTester tester,
    AppController controller, {
    double width = 300,
    double height = 620,
  }) async {
    final pageCtrl = PageController();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: SidePanel(
            controller: controller,
            pageCtrl: pageCtrl,
            onOpenCalendar: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Mainline sample() => Mainline(
        id: 'ml-1',
        title: '论文冲刺',
        created: DateTime(2026, 10, 18, 9),
        steps: [
          MainlineStep(
            title: '列提纲',
            done: true,
            doneAt: DateTime(2026, 10, 19, 9),
          ),
          const MainlineStep(title: '写第三章'),
          const MainlineStep(title: '通读一遍'),
        ],
      );

  /// 在日历上按住 [from] 号拖到 [to] 号（记录页的拖选）。
  Future<void> dragDays(WidgetTester tester, int from, int to) async {
    final start = tester.getCenter(find.text('$from'));
    final end = tester.getCenter(find.text('$to'));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('没有主线：顶栏第二行是新建入口，点开是空态，照样能翻到记录页', (tester) async {
    final controller = makeController();
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    expect(find.text('＋ 新建主线'), findsOneWidget);

    await tester.tap(find.text('＋ 新建主线'));
    await tester.pumpAndSettle();
    expect(find.text('还没有主线'), findsOneWidget);
    expect(find.text('新建主线'), findsOneWidget);

    // 记录页与主线无关：没有主线时那颗 `1/2` 也在，点它就能过去
    final now = DateTime.now();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(controller.mainlineOpen, isTrue);
  });

  testWidgets('有主线：顶栏显示名字与进度，点开盖住面板显示行为链', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    // 第二行：名字 + 进度（1/3）
    expect(find.text('论文冲刺'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();

    // 覆盖页：自带返回 + 步骤 + 归档入口
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('列提纲'), findsOneWidget);
    expect(find.text('写第三章'), findsOneWidget);
    expect(find.text('通读一遍'), findsOneWidget);
    expect(find.textContaining('归档 ·'), findsOneWidget);

    // 返回 → 回到原来的四页
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('列提纲'), findsNothing);
    expect(find.text('论文冲刺'), findsOneWidget);
  });

  testWidgets('步骤标题过长换行：不再截成一行', (tester) async {
    const long = '学习数模电、数理，边做项目边补，先把第三章写完再回头补附录里的推导和实验数据';
    final controller = makeController(prefix: [
      Mainline(
        id: 'ml-long',
        title: '长标题',
        created: DateTime(2026, 10, 1, 9),
        steps: const [MainlineStep(title: long)],
      ),
    ]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('长标题'));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.text(long));
    expect(size.height, greaterThan(30), reason: '至少两行，单行只有十几 dp');
  });

  testWidgets('行为链滚到底再上滑：覆盖页收回', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    expect(controller.mainlineOpen, isTrue);

    // 行为链不满一屏，已经"在底"：往上拖就是末尾之后的那一下。
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(controller.mainlineOpen, isFalse);
    expect(find.text('列提纲'), findsNothing);
  });

  testWidgets('覆盖页进出都是滑动：途中在落点上方，退场滑完才摘子树', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final midTop = tester.getTopLeft(find.text('写第三章')).dy;

    await tester.pumpAndSettle();
    final restTop = tester.getTopLeft(find.text('写第三章')).dy;

    // 整块从面板顶边上方滑下来：半路上还离落点一段距离
    expect(midTop, lessThan(restTop - 40));

    // 退场同一条路：点返回后先滑上去，途中覆盖页仍在树上（编辑态与守卫不能提前撤）
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('写第三章'), findsOneWidget);
    expect(tester.getTopLeft(find.text('写第三章')).dy, lessThan(restTop - 40));

    // 滑完才摘：覆盖页整块消失，回到底下的四页
    await tester.pumpAndSettle();
    expect(find.text('写第三章'), findsNothing);
    expect(find.text('论文冲刺'), findsOneWidget);
  });

  testWidgets('覆盖页铅笔进编辑态：可加一步、保存后进度跟着变', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('编辑主线'), findsOneWidget);
    expect(find.text('添加一步'), findsOneWidget);

    await tester.tap(find.text('添加一步'));
    await tester.pumpAndSettle();
    // 新那一步是空输入框（提示文案 = 第 4 步）
    expect(find.text('第 4 步'), findsOneWidget);

    final field = find.widgetWithText(TextField, '第 4 步');
    await tester.enterText(field, '补附录');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    final saved = controller.activeMainline!;
    expect(saved.steps.length, 4);
    expect(saved.steps.last.title, '补附录');
    expect(find.text('编辑主线'), findsNothing);
  });

  testWidgets('记录页：按住拖选一段 → 写文字 → 常驻列在记录列表', (tester) async {
    // 记录页的日历默认停在**当月**：标签与圈出来的日期都得跟着今天走，
    // 写死月份的话跨月就红（2026-11 踩过一次）。
    final now = DateTime.now();
    final monthLabel = '${now.year} 年 ${now.month} 月';
    final controller = makeController(prefix: [
      Mainline(
        id: 'ml-2',
        title: '写作',
        created: DateTime(2026, 10, 1, 9),
        steps: const [MainlineStep(title: '开头')],
      ),
    ]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    // 页头 1/2 = 翻到记录（记录页里横滑归日历，翻页只能点它）
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text(monthLabel), findsOneWidget);

    await dragDays(tester, 19, 21);

    expect(find.text('这一段记点什么'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '补记三天');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final logs = controller.logBook.segments;
    expect(logs, hasLength(1));
    expect(logs.single.start, DateTime(now.year, now.month, 19));
    expect(logs.single.end, DateTime(now.year, now.month, 21));
    expect(logs.single.text, '补记三天');
    // 文字默认就在下半区，不用点某一天
    expect(find.text('本月记录 · 1 段'), findsOneWidget);
    expect(find.text('补记三天'), findsOneWidget);
  });

  testWidgets('记录页下半区向右滑 → 回行为链（日历区域仍归拖选日期）', (tester) async {
    final now = DateTime.now();
    final monthLabel = '${now.year} 年 ${now.month} 月';
    final controller = makeController(prefix: [
      Mainline(
        id: 'ml-3',
        title: '写作',
        created: DateTime(2026, 10, 1, 9),
        steps: const [MainlineStep(title: '开头')],
      ),
    ]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text(monthLabel), findsOneWidget);

    // 空提示那块 = 下半区：向右拖 → 回行为链
    await tester.drag(
      find.text('按住日历拖选一段日期写记录；向右滑回主线'),
      const Offset(160, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('开头'), findsOneWidget);
    expect(find.text(monthLabel), findsNothing);
  });

  testWidgets('记录页：点记录卡改文字，改的是那一条', (tester) async {
    final now = DateTime.now();
    final controller = makeController(
      prefix: [
        Mainline(
          id: 'ml-5',
          title: '写作',
          created: DateTime(2026, 10, 1, 9),
          steps: const [MainlineStep(title: '开头')],
        ),
      ],
      segments: [
        LogSegment.range(
          start: DateTime(now.year, now.month, 11),
          end: DateTime(now.year, now.month, 12),
          text: '这一段在改稿',
        ),
      ],
    );
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();

    // 文字常驻在下半区，不用点开；点 11 号只是高亮对应那张卡
    expect(find.text('本月记录 · 1 段'), findsOneWidget);
    expect(find.text('这一段在改稿'), findsOneWidget);
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('这一段在改稿').last);
    await tester.pumpAndSettle();
    expect(find.text('改这一段'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '改成新的说法');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final logs = controller.logBook.segments;
    expect(logs, hasLength(1));
    expect(logs.single.text, '改成新的说法');
    expect(logs.single.start, DateTime(now.year, now.month, 11));
  });

  testWidgets('记录页：多段文字默认全展开，不用点某天', (tester) async {
    final now = DateTime.now();
    final controller = makeController(
      prefix: [
        Mainline(
          id: 'ml-6',
          title: '写作',
          created: DateTime(2026, 10, 1, 9),
          steps: const [MainlineStep(title: '开头')],
        ),
      ],
      segments: [
        LogSegment.range(
          start: DateTime(now.year, now.month, 2),
          end: DateTime(now.year, now.month, 5),
          text: '做 dashboard、笔记插件助手、文档维护系统',
        ),
        LogSegment.range(
          start: DateTime(now.year, now.month, 9),
          end: DateTime(now.year, now.month, 12),
          text: '写架构文档 v2',
        ),
      ],
    );
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();

    expect(find.text('本月记录 · 2 段'), findsOneWidget);
    expect(find.text('做 dashboard、笔记插件助手、文档维护系统'), findsOneWidget);
    expect(find.text('写架构文档 v2'), findsOneWidget);
    expect(find.textContaining('· 4 天'), findsNWidgets(2));
  });

  testWidgets('记录页：点月头年月切成月记，写一句落库，再点切回日历', (tester) async {
    final controller = makeController(prefix: [
      Mainline(
        id: 'ml-4',
        title: '写作',
        created: DateTime(2026, 10, 1, 9),
        steps: const [MainlineStep(title: '开头')],
      ),
    ]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('写作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();

    // 日历落在哪个月由真实时钟决定，所以期望文本也照它算。
    final now = DateTime.now();
    final monthLabel = '${now.year} 年 ${now.month} 月';

    await tester.tap(find.text(monthLabel));
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年'), findsOneWidget);
    expect(find.text('记一句'), findsNWidgets(12), reason: '一年十二行，一月都没写');

    await tester.tap(find.text('${now.month} 月'));
    await tester.pumpAndSettle();
    expect(find.text('一个月写一句：这个月在做什么'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '把第三章写完');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final note = controller.logBook.monthNoteOf(now.year, now.month);
    expect(note?.text, '把第三章写完');
    expect(find.text('把第三章写完'), findsOneWidget);
    expect(find.text('记一句'), findsNWidgets(11), reason: '写过的那行不再提示');

    // 再点年份 → 切回月历
    await tester.tap(find.text('${now.year} 年'));
    await tester.pumpAndSettle();
    expect(find.text(monthLabel), findsOneWidget);
  });

  testWidgets('窄面板 240dp：顶栏两行与覆盖页都不溢出', (tester) async {
    final now = DateTime.now();
    final monthLabel = '${now.year} 年 ${now.month} 月';
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller, width: 240, height: 480);

    expect(find.text('论文冲刺'), findsOneWidget);
    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    expect(find.text('写第三章'), findsOneWidget);

    // 切到记录页：日历在 240×480 的剩余高度里也要能画出来
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text(monthLabel), findsOneWidget);
  });

  testWidgets('没勾完：废弃在进度行右端，确认后归档、顶栏回到新建入口', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();

    // 没勾完 → 进度行右端是废弃；标题行不再有那颗图标
    final overlay = find.byType(MainlineOverlay);
    final abandon = find.descendant(of: overlay, matching: find.text('废弃'));
    expect(abandon, findsOneWidget);
    expect(find.byTooltip('废弃主线'), findsNothing);
    expect(find.byTooltip('完成主线'), findsNothing);
    // 在进度行上，不在标题行：比标题行那颗名字低一截
    expect(
      tester.getCenter(abandon).dy,
      greaterThan(
        tester
                .getCenter(find.descendant(
                    of: overlay, matching: find.text('论文冲刺')))
                .dy +
            20,
      ),
    );

    await tester.tap(abandon);
    await tester.pumpAndSettle();
    expect(find.text('废弃这条主线？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '废弃'));
    await tester.pumpAndSettle();

    // 覆盖页收起，顶栏回到新建入口；归档里那一条标"已废弃"
    expect(find.text('＋ 新建主线'), findsOneWidget);
    expect(controller.activeMainline, isNull);
    final archived = controller.archivedMainlines.single;
    expect(archived.isAbandoned, isTrue);
    expect(archived.completedAt, isNull);
    expect(archived.steps, hasLength(3), reason: '归档不删数据');
  });

  testWidgets('归档主线不动记录：归档之后记录页照样进得去、写得进', (tester) async {
    final controller = makeController(prefix: [sample()]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    await dragDays(tester, 19, 21);
    await tester.enterText(find.byType(TextField).last, '第一段');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.logBook.segments, hasLength(1));

    // 回到行为链，把主线废弃掉（覆盖页随之收起）
    await tester.drag(
      find.text('本月记录 · 1 段'),
      const Offset(160, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('废弃'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '废弃'));
    await tester.pumpAndSettle();
    expect(controller.activeMainline, isNull);

    // 没有主线了：一样点开 → 翻到记录页 → 那一段还在，还能再圈一段
    await tester.tap(find.text('＋ 新建主线'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/2'));
    await tester.pumpAndSettle();
    expect(find.text('第一段'), findsOneWidget);

    await dragDays(tester, 10, 11);
    await tester.enterText(find.byType(TextField).last, '第二段');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.logBook.segments, hasLength(2));
    expect(find.text('本月记录 · 2 段'), findsOneWidget);
  });

  testWidgets('归档列表：两类并排、各带徽标与日期，点一条进只读页（单页）', (tester) async {
    final controller = makeController(prefix: [
      sample(),
      Mainline(
        id: 'ml-old',
        title: '旧方向',
        created: DateTime(2026, 8, 1),
        abandonedAt: DateTime(2026, 9, 2, 18),
      ),
      Mainline(
        id: 'ml-done',
        title: '做完了的',
        created: DateTime(2026, 7, 1),
        completedAt: DateTime(2026, 9, 20, 18),
      ),
    ]);
    await boot(tester, controller);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('论文冲刺'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('归档 ·'));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text('已废弃')),
        findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('已完成')),
        findsOneWidget);
    expect(find.textContaining('09-02'), findsOneWidget);
    expect(find.textContaining('09-20'), findsOneWidget);

    await tester.tap(find.text('旧方向'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已归档 · 2026-09-02 废弃'), findsOneWidget);
    expect(find.text('返回当前'), findsOneWidget);
    // 只读 + 单页：没有编辑、没有废弃/完成，也没有 1/2
    expect(find.byTooltip('编辑'), findsNothing);
    expect(find.text('废弃'), findsNothing);
    expect(find.text('1/2'), findsNothing);
  });
}
