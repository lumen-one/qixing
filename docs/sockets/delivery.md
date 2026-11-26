# 交付类插座

"到点把提醒送到用户眼前"这一侧的全部插座：通知、闹钟、权限、目录选择，以及桌面与
安卓两套适配器。末尾是系统级悬浮面板（第二个 Flutter 引擎）的层职责与引擎边界。

## 接口

```dart
enum ReminderChannel { ring, silent, alarm }   // ring = 提示音 + 震动；silent = 只横幅（仅编排条目）；alarm = 全屏 + 持续响铃
enum PermissionKind {
  notifications, exactAlarm, batteryExemption,
  overlayWindow,        // 悬浮侧边栏（SYSTEM_ALERT_WINDOW）
  showOnLockScreen,     // 全屏提醒（锁屏/上层显示）
  folderAccess,         // 任务目录（所有文件访问 或 SAF）
}

class NotificationAction { final String id; final String label; }  // 如 done / snooze1h

/// 交付内容草案：挂闹钟时就把"到点交付什么"定下来。
/// 桌面不需要（到点由应用自己 show）；安卓需要——系统闹钟到点时应用可能已被杀，
/// 原生接收器只能照这份草案自己弹通知。
class ReminderDraft {
  final String taskId; final String title; final String? body;
  final ReminderChannel channel; final bool fullScreen;
  final List<NotificationAction> actions;
}

abstract class NotificationPort {
  Future<void> show(ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,        // full-screen intent（闹钟）
    ReminderDraft? draft,           // 系统通知实现用它渲染文案
  });
  /// 桌面的"托盘"就是应用窗口：适配器把 show 回流给 UI 渲染弹窗；
  /// 系统通知实现返回空流（安卓的按钮/点击走原生事件回传，见 4.3）。
  Stream<ShownNotification> get shown;
}

/// 持续响铃：与通知分开的一条通道——通知是"留在那儿的消息"，铃声是"现在就要你注意"。
/// 循环播放，到 [seconds] 自停；[stop] 供全屏页与通知按钮提前停。桌面壳没有这个能力
/// （`ShellCapabilities.alarmChannel` 为 false），装配点注入 null、分发器就不起铃。
abstract class AlarmRingPort {
  Future<void> start(String taskId, {required int seconds});
  Future<void> stop(String taskId);
  String? get ringingTaskId;      // 正在响的那一件；null = 没在响
}

/// 一个待触发的站点。静态站点（时点提醒、编排、每日收尾）重锚时一次排全交给原生存盘，
/// 到点由原生自己投递，不依赖 Dart 进程还在。
class AlarmStation {
  final DateTime at;
  final ReminderDraft draft;   // draft.taskId 就是站点 id
}

/// 一次闹钟到点回调。delivered = 系统侧已经把这条提醒弹给用户了（安卓原生接收器
/// 照着挂站时的草案自己投递；桌面没有这一层，恒 false）。
///
/// 安卓的事件还带**站点身份**：哪一格、原定几点、该交付什么。应用被杀期间原生会
/// 连续投递多站，事件攒在队列里、下次启动一次回放——只给 taskId 时 Dart 只能按
/// "现在"重算该弹谁，几条叠在一起就会把账记到错的人头上
/// （见 sockets/reminder.md）。
class FiredAlarm {
  final String taskId;
  final bool delivered;
  final DateTime? at;          // 站点表里这一格的原定时刻（ReminderExtras.AT_MILLIS）
  final String? stationKey;    // 站点表主键 <taskId>@<atMillis>（ReminderExtras.STATION_KEY）
  final ReminderDraft? draft;  // 挂站那一刻定稿的交付草案
  bool get hasStation => at != null && draft != null;   // false = 桌面 / 升级前入队的事件
}

abstract class AlarmPort {
  /// 用整张站点表替换当前所有闹钟：先取消旧的，再逐站挂上。
  /// 安卓把表持久化到原生 prefs，开机 / 应用更新后自行恢复；桌面只取最早一站。
  Future<void> scheduleStations(List<AlarmStation> stations);
  Future<void> cancel();
  /// 到点（安卓=系统闹钟回调；桌面=Timer）。带站点身份的事件由分发器按站记账，
  /// 不带的（桌面、升级前入队）退回"按现在重算"。
  Stream<FiredAlarm> get fired;
}

abstract class FolderPickerPort {
  Future<String?> pickDirectory();
  Future<String?> pickFile({required String dialogTitle,
      required List<String> allowedExtensions});  // 灵感文件路径：真实路径，非缓存副本（见 ../panels/notes.md）
}  // SAF / 桌面选择器

abstract class PermissionPort {
  Future<bool> ensure(PermissionKind kind);   // 申请（必要时弹系统界面）
  Future<bool> granted(PermissionKind kind);  // 只查询（设置页展示，不弹界面）
}
```

桌面适配器（`lib/platform/desktop_adapters.dart`）：`TimerAlarmPort`（前台 Timer，
系统闹钟在桌面的等价物）、`StreamNotificationPort`（应用内弹窗回流）、
`GrantedPermissionPort`、`DesktopFolderPickerPort`（**文件可挑，目录仍不挑**——
桌面任务目录走环境变量 `GTD_TASKS_DIR` / 引导配置，不做目录选择 UI）。

安卓适配器（`lib/platform/android_adapters.dart` + `android/…/com/lumenone/qixing/` 原生侧）：
`AndroidAlarmPort` / `AndroidNotificationPort` / `AndroidAlarmRingPort`（`AlarmManager.setAlarmClock()`
逐站挂站点表并存进原生 prefs，开机由 `BootReceiver` 恢复；通知渠道
`gtd_ring`/`gtd_silent`/`gtd_alarm`/`gtd_ringing`/`gtd_overlay` +
通知按钮 + full-screen intent + 循环铃声服务 `AlarmRingService`（它自己的前台通知走
`gtd_ringing`，静音——声音归播放器，不归渠道）；`gtd_ring` 与 `gtd_silent` 都是
IMPORTANCE_HIGH——横幅必现，区别只在有没有声音与震动，`silent` 只给编排条目）、
`AndroidPermissionPort`（permission_handler + 原生全屏 intent/悬浮窗查询）、
`AndroidFolderPickerPort`（所有文件访问 + 系统目录选择器；挑文件走自建 SAF
`pickMarkdownFile`，把 documentId 换成真实路径，**不经 file_picker**——它挑文件只回缓存
副本，见[决策卡](../decisions/2026-10-24-android-markdown-pick.md)）；
原生侧另有 `OverlayHandleService`（贴屏把手 + 悬浮面板窗口，前台服务 + WindowManager）：
它从 `stopWithTask=false` 起就与 Activity 解绑，划掉任务卡片不停止服务，把手与面板
照常（生命周期见 [architecture.md](../architecture.md) §5.1）。
`platform/` 不受 [architecture.md](../architecture.md) §2 矩阵约束（组装点装配），但不得被 domain/scheduler/application import。

**到点事件的载荷（`alarmFired`）**：原生接收器发事件时带上这一站的完整身份——除了
`taskId` / `delivered`，还有 `stationKey`、`atMillis` 与草案六项（`title` / `body` /
`channel` / `fullScreen` / `actionIds` / `actionLabels`）。键名全部沿用 `ReminderExtras`，
草案从挂站的 intent 里读回来（`putReminderExtras` 已经写全），不另存一份。分发器靠它
按站记账与补投；缺这几项的事件（桌面 Timer、升级前入队的事件）走旧路径。

事件队列是"写 JSON 再读回"的一趟：`JSONObject` 会把字符串数组存成 `JSONArray`，
`NativeEventQueue` 读回时递归转成 `ArrayList` 与 `LinkedHashMap`。原样交给
`StandardMessageCodec` 会抛"不支持的类型"，`drainEvents` 在 Dart 侧被 catch 掉，
整批事件一次都取不回来——看起来像"应用被杀期间什么都没发生"。

**系统级悬浮面板（第二个 Flutter 引擎）**：[architecture.md](../architecture.md) §0 的产品定位是"日常操作发生在
悬浮侧边栏里，App 主体几乎不开"，所以把手拖出必须**在当前 App 上方就地展开面板**，
而不是跳进应用。实现：

| 层                | 位置                                                    | 职责                                                                                                     |
| ----------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 原生命令/事件通道 | `gtd/overlay`（MethodChannel）                          | 上行：`notifyReady` / `collapse` / `expand` / `openApp{target,routineId}` / `panelWidth{dp}`；下行：`state{expanded,dockedRight,handleCenterY}` / `panelDrag{dx}` / `panelDragEnd{open}` / `quickNoteStart` / `quickNoteCancel` / `quickNoteOpen{x,y}` |
| 第二个引擎入口    | `lib/overlay_main.dart`（DartEntrypoint `overlayMain`） | 只剩入口与装配：装配**同一套** domain/application（自己的实例）；通道桥与面板宿主壳 `OverlayBridge` / `OverlayPanelShell` 在 `lib/ui/overlay/`                        |
| 面板本体          | `lib/ui/panels/side_panel.dart`                         | `SidePanel` / `PullOverlayReveal` / `QuickNoteLayer`（拖出头快记）/ `PanelOnboardDialog`：**悬浮面板与 App 内抽屉共用同一份**（快记只在悬浮窗用） |
| 窗口              | 原生 `OverlayHandleService`                             | 全屏**透明** `TYPE_APPLICATION_OVERLAY` 窗口承载引擎的 FlutterView；展开时隐藏原生把手                   |

> `handleCenterY`（逻辑像素）= 原生把手的中心 Y：面板垂直居中于它（ui-interaction.md
> [把手与面板](../panels/handle.md)）；字段缺失（老版本原生 / 桌面）时 Dart 侧贴顶展开，向后兼容。

边界（写死，避免两个引擎打架）：

1. **交付类插座与观察类订阅者只在主引擎装配**：站点表由主引擎那一份下发，悬浮引擎
   不起 ReminderDispatcher（两个引擎各下发一张表会互相覆盖）；`EventLog`（操作流水）
   同理只在主引擎挂，否则同一件事会被记两遍；
2. **写路径仍然唯一**：悬浮面板的命令同样走它自己的 `TaskService`（C1 不变），
   两个引擎之间的状态同步走**文件**——两边都 `watch()` 任务目录（与"Obsidian 手改
   回流"同一条通路），并发写由字段归属合并兜底；
3. **进应用的唯一入口**是面板头部的『设置』与实例菜单的『编辑规则』
   （`openApp{target,routineId}`），其余交互全部就地完成。

**站点表职责归属（条款有主语）**：调用方 = application 层的 **ReminderDispatcher**
（见 [reminder.md](reminder.md)），它把重锚那一刻能算出的所有静态站点一次排全交给
`AlarmPort`；装配点负责注入。**适配器不重排站点，但负责把它们保住**：安卓把整张表
写进原生 prefs，用 `AlarmManager.setAlarmClock()` 逐站挂上（用户可见的闹钟，Doze 与
厂商省电策略不推迟，也不吃 `SCHEDULE_EXACT_ALARM` 授权）；`BootReceiver` 在开机、
应用更新后读表重挂，不需要等 Dart 进程起来；`ReminderReceiver` 到点只投这一站、
把表里的这一项标成已投，其余站点原样留着，由 Dart 的下一次重锚覆盖整表。桌面没有
系统闹钟，`TimerAlarmPort` 只取最早一站。
