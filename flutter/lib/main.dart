// voice_ui：fcitx5-aiinput 的浮窗 UI（MD3）
//
// 运行方式：Flutter 引擎进程内嵌入 fcitx5 addon（raw embedder API +
// kSoftware 软渲染），无 GTK 窗口/无独立进程——引擎把整窗帧直接交给
// addon 写入 zwp_input_popup_surface_v2 的 shm buffer。
//
// 尺寸策略（收窄卡片：与文本框等宽过于抢眼）：
//   会话三态（录音/结果/候选）是同一张卡片、同一套公式：宽度
//   clamp(单行实测, 360, 420)；高度 = 头部 + 行基数 + 换行增量（长文本
//   软换行完整显示，不截断不滚动；0.95 悲观测量防溢出）。录音中的
//   流式 partial 即主文本行，结束时原位过渡为候选「原始版」行。
//   实际窗口尺寸 = 卡片 + 四周 kShadowPad 阴影余量，变化时回发 resize。
//
// 协议（channel 'fcitx5/flutterui'，JSONMethodCodec）：
//   C++→Dart : MethodCall('update', {state, partial, elapsed_ms, final,
//                 timeout_ms, candidates, hover, anim})
//              anim = 动画速率挡位系数（慢 1.8/标准 1.0/快 0.6，
//              configtool UiAnimSpeed 热改即时生效；font 消息同样携带）
//   Dart→C++ : invokeMethod('ready')
//              invokeMethod('resize', {w, h})     // 含阴影余量的整窗尺寸
//              invokeMethod('select', {index, panel?})  // panel=true 走输入法候选
//              invokeMethod('hover', {row})       // 测试观测用
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mock_host.dart';

const double kMaxW = 420;
// 卡片阴影余量：快照区比卡片四周各大这么多（BoxShadow blur10+spread1
// 超出边界 ~11px）；指针坐标是含余量的表面局部坐标，Padding 天然吸收
const double kShadowPad = 12;
// 增长余量（曾为 20：吸收 resize 跟进前的过渡帧——窗口改跟内容实
// 尺寸后无用，只余每侧死边距：卡片被推离光标 + 下方悬停死区）
const double kGrowthSlack = 0;

// 全局动画时长：基准毫秒 × 挡位系数（与 C++ animScaleOf 对应：快 1.0/
// 标准 1.6/慢 3.0，默认慢速——挡位由 C++ 随每条 update/font 消息下发）
const double kDefaultAnimScale = 3.0;
Duration animDurOf(double scale, int baseMs) =>
    Duration(milliseconds: (baseMs * scale).round());

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // raw embedder 引擎不走 fontconfig（无系统字体 fallback），CJK 字体
  // 打进 assets 并运行时注册（legacy `flutter build bundle` 不生成
  // pubspec fonts: 的 FontManifest，故不走 theme.fontFamily 的静态解析）
  final loader = FontLoader('NotoSansSC')
    ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
  await loader.load();
  // 传输选择（协议 v1，lab/spec/protocol.md）：默认嵌入态 channel；
  // UI_TRANSPORT=mock + UI_REPLAY=<jsonl> 时用回放宿主驱动（试验田/
  // flutter run 演示），UI 发出的命令由 MockHost 记录打印
  final env = Platform.environment;
  if (env['UI_TRANSPORT'] == 'mock') {
    final script = env['UI_REPLAY'] ?? '';
    final host = MockHost();
    if (script.isNotEmpty && File(script).existsSync()) {
      final lines = File(script).readAsLinesSync();
      final envelopes = lines
          .where((l) => l.trim().isNotEmpty)
          .map((l) => Map<String, dynamic>.from(
              const JsonDecoder().convert(l) as Map))
          .toList();
      unawaited(host.play(MockHost.fromEnvelopes(envelopes)));
    }
    runApp(VoiceUiApp(transport: host));
    return;
  }
  runApp(const VoiceUiApp());
}

// ---------------------------------------------------------------------------
// 会话状态（addon 下发；录音计时本地续走）
// ---------------------------------------------------------------------------
enum UiState { idle, recording, result, candidates }

class SessionData {
  final UiState state;
  final String partial; // 流式中间结果（尾部优先实时显示）
  final String resultText; // 最终文本
  final List<String> candidates; // 候选（首个=润色版）
  final int elapsedMs; // 录音计时
  final int timeoutMs; // result 停留时长（倒计时条）
  final int hover; // 键盘方向键选择行（-1=无；鼠标 hover 是本地状态）
  final bool llmDummy; // LLM 为占位档（润色行打 Dummy 标记）
  const SessionData({
    this.state = UiState.idle,
    this.partial = '',
    this.resultText = '',
    this.candidates = const [],
    this.elapsedMs = 0,
    this.timeoutMs = 1500,
    this.hover = -1,
    this.llmDummy = false,
  });
}


/// IM 候选面板数据（panel/update 事件——pinyin/rime 等引擎的候选窗）
class PanelData {
  final List<PanelCandidate> candidates;
  final int cursor;
  final bool isVertical;
  final String auxUp;
  final String imName;
  const PanelData({
    this.candidates = const [],
    this.cursor = -1,
    this.isVertical = false,
    this.auxUp = '',
    this.imName = '',
  });
}

class PanelCandidate {
  final String label;
  final String text;
  final String comment;
  const PanelCandidate(this.label, this.text, {this.comment = ''});
}

// ---------------------------------------------------------------------------
// App 根
// ---------------------------------------------------------------------------
class VoiceUiApp extends StatelessWidget {
  const VoiceUiApp({super.key, this.transport});

  final UiTransport? transport; // null=嵌入态默认 channel

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'voice_ui',
      theme: ThemeData(
        useMaterial3: true,
        // raw embedder 无 fontconfig：CJK 用打包的 NotoSansSC 兜底；
        // classicui 跟随字体（SysFont）在 Home 层覆盖
        fontFamily: 'NotoSansSC',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      ),
      home: VoiceUiHome(transport: transport ?? const ChannelTransport()),
    );
  }
}

class VoiceUiHome extends StatefulWidget {
  const VoiceUiHome({super.key, this.transport = const ChannelTransport()});

  final UiTransport transport;

  @override
  State<VoiceUiHome> createState() => _VoiceUiHomeState();
}

class _VoiceUiHomeState extends State<VoiceUiHome> {
  SessionData _data = const SessionData();
  Timer? _ticker;
  int _localElapsed = 0;
  String? _sysFontFamily; // classicui 跟随字体（FontLoader 注册后启用）
  double _fontScale = 1.0; // size/12 基准
  double _animScale = kDefaultAnimScale; // 动画速率挡位系数
  int _mouseHover = -1; // 鼠标悬停行（本地状态；键盘选择走 data.hover）
  PanelData? _panel; // IM 候选面板（panel/update 事件驱动；null=隐藏）
  Size _lastReported = Size.zero;
  final GlobalKey _cardKey = GlobalKey(); // 卡片实际尺寸回读（布局后）
  // 内容实尺寸（VoicePanel 自然尺寸）：窗口上报的度量源。AnimatedSize
  // 的盒子是"动画中的视觉裁剪"，会滞留在中间值——曾致窗口比内容小、
  // 行的命中区伸出可见卡片之外（卡片下方仍能悬停到行）
  final GlobalKey _panelKey = GlobalKey();

  void _invoke(String method, [Map<String, dynamic>? args]) {
    widget.transport.send(method, args ?? const {});
  }

  @override
  void initState() {
    super.initState();
    widget.transport.attach(_onTransportMessage);
    _invoke('ready');
    // 持久帧回调：每帧布局完成后回读卡片尺寸、变化即上报。不能挂在
    // build 的 post-frame 上——AnimatedSize 等动画只在 render 层逐帧
    // 进行不触发 build，最终尺寸曾因此漏报（展开形态被旧窗口裁掉，
    // 直到下一次 setState 才"神奇恢复"）
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      if (!mounted) return;
      var ro = _panelKey.currentContext?.findRenderObject();
      ro ??= _cardKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        _reportSize(ro.size);
      }
    });
  }

  void _reportSize(Size card) {
    // 窗口 = 卡片 + 四周 kShadowPad 阴影余量，实时精确跟随（不量化）：
    // 尺寸源是 _panelKey 自然尺寸，状态切换一步到位而非逐帧生长，每会话
    // 仅数次 resize；shm 池桶内换 buffer 代价低。量化步进只剩死边距
    //（卡片下方红区悬停到行的空间就是这么来的）
    final win = Size(
      (card.width + (kShadowPad + kGrowthSlack) * 2).ceilToDouble(),
      (card.height + (kShadowPad + kGrowthSlack) * 2).ceilToDouble(),
    );
    if (win != _lastReported) {
      // setState 必须有：SizedBox(_lastReported) 是布局输入，不重建则
      // 卡片钉在旧窗口里不重新居中——命中布局与渲染视图脱时代（长文本
      // 卡片最明显：hover 整体偏移的根源）
      setState(() => _lastReported = win);
      _invoke('resize', {'w': win.width.ceil(), 'h': win.height.ceil()});
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // 宿主→UI 消息入口（协议 v1 单契约；legacy 'update' wire 已随 addon
  // 发射器切换删除）
  void _onTransportMessage(String method, Map<String, dynamic> args) {
    final animScale = (args['anim'] as num?)?.toDouble();
    if (animScale != null) _animScale = animScale;
    switch (method) {
      case 'theme':
        _applyFont(args['font_path'] as String? ?? '',
            (args['font_size'] as num?)?.toDouble() ?? 12);
        break;
      case 'voice/recording':
        _localElapsed = (args['elapsed_ms'] as num?)?.toInt() ?? 0;
        var partial = args['partial'] as String? ?? '';
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
          _localElapsed += 100;
          _update(SessionData(
            state: UiState.recording,
            partial: partial,
            elapsedMs: _localElapsed,
          ));
        });
        _update(SessionData(
          state: UiState.recording,
          partial: partial,
          elapsedMs: _localElapsed,
        ));
        break;
      case 'voice/result':
        _ticker?.cancel();
        _update(SessionData(
          state: UiState.result,
          resultText: args['final'] as String? ?? '',
          timeoutMs: (args['timeout_ms'] as num?)?.toInt() ?? 1500,
        ));
        break;
      case 'voice/candidates':
        _ticker?.cancel();
        final int msgHover = (args['hover'] as num?)?.toInt() ?? -1;
        // hover 值 ≠ 本地悬停 = 键盘改了选择（或新会话）→ 悬停让位，
        // 方向键接管显示；鼠标再次移动经 onHover 重新接管
        _mouseHover = msgHover == _mouseHover ? _mouseHover : -1;
        _update(SessionData(
          state: UiState.candidates,
          resultText: args['final'] as String? ?? '',
          candidates:
              (args['candidates'] as List?)?.cast<String>() ?? const [],
          hover: msgHover,
          llmDummy: args['llm_dummy'] == true,
        ));
        break;
      case 'voice/idle':
        _ticker?.cancel();
        _mouseHover = -1;
        _update(const SessionData());
        break;
      case 'panel/update':
        _ticker?.cancel();
        _mouseHover = -1;
        final cands = (args['candidates'] as List? ?? const [])
            .map((c) => PanelCandidate(
                (c as Map)['label'] as String? ?? '',
                c['text'] as String? ?? '',
                comment: c['comment'] as String? ?? ''))
            .toList();
        setState(() => _panel = PanelData(
            candidates: cands,
            cursor: (args['cursor'] as num?)?.toInt() ?? -1,
            isVertical: args['layout'] == 'vertical',
            auxUp: args['aux_up'] as String? ?? '',
            imName: args['im_name'] as String? ?? ''));
        break;
      case 'panel/hide':
        _ticker?.cancel();
        setState(() => _panel = null);
        break;
      default:
        // 协议约定：未知 method 忽略，向前兼容
        break;
    }
  }

  void _selectPanelCandidate(int index) {
    if (_panel == null || index < 0 || index >= _panel!.candidates.length) {
      return;
    }
    _invoke('select', {'index': index, 'panel': true});
  }

  void _update(SessionData d) {
    setState(() => _data = d);
    // 尺寸上报统一走 build 的后置帧回读（实际渲染尺寸）
  }

  /// 系统字体应用：文件加载进 FontLoader('SysFont')，12pt 为 1.0 基准缩放
  Future<void> _applyFont(String path, double size) async {
    try {
      if (path.isNotEmpty && File(path).existsSync()) {
        final bytes = await File(path).readAsBytes();
        final loader = FontLoader('SysFont')
          ..addFont(Future.value(bytes.buffer.asByteData()));
        await loader.load();
        setState(() {
          _sysFontFamily = 'SysFont';
          _fontScale = (size / 12.0).clamp(0.7, 2.5);
        });
        // 字体变化 → 尺寸变化由 build 的后置帧上报（此处主题尚未重建）
        // ignore: avoid_print
        print('ui-font: $path size=$size');
        return;
      }
    } catch (e) {
      // ignore: avoid_print
      print('ui-font failed: $e');
    }
    // 兜底：仅字号缩放（内置 NotoSansSC）
    setState(() => _fontScale = (size / 12.0).clamp(0.7, 2.5));
  }

  void _onHoverRow(int row) {
    if (_mouseHover != row) {
      // ignore: avoid_print
      print('ui-hover: row=$row');
    }
    if (_mouseHover != row) {
      setState(() => _mouseHover = row);
      _invoke('hover', {'row': row});
    }
  }

  void _selectCandidate(int index) {
    _invoke('select', {'index': index});
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = base.copyWith(
      // SysFont = classicui 跟随/UIFont 配置（_applyFont 注册）；
      // 字号以 classicui Font 的 pt 为基准（12 → 1.0）。
      // Theme.of 的主题已规范化（样式字号非空），apply 才不触发断言
      textTheme: base.textTheme.apply(
        fontFamily: _sysFontFamily ?? 'NotoSansSC',
        fontFamilyFallback: const ['NotoSansSC'],
        fontSizeFactor: _fontScale,
      ),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          // 窗口 = 上次上报尺寸：Align 向下传松约束，内容按自然尺寸布局
          //（增长的一帧内新内容落在透明余量里，下一帧 resize 跟上——
          // 结构上不可能出现 overflow 条纹，与字体测量无关）
          child: SizedBox(
            width: _lastReported.width,
            height: _lastReported.height,
            // OverflowBox 无界约束：卡片按自然尺寸布局（窗口 0×0 引导期
            // 也能长出真实大小——Align/Padding 的松约束上限=窗口尺寸，
            // 曾把尺寸回读环死锁在初始 56×56）；超出窗口的部分由 surface
            // 裁掉，kGrowthSlack 余量兜住 resize 跟进前的过渡帧
            child: OverflowBox(
              // 顶部对齐：卡片贴住表面顶（= 光标下方），量化余量全部
              // 沉到底部——居中对齐会把卡推离光标形成视觉空隙
              // 顶部对齐但留 kShadowPad：阴影向上溢出卡片边界，贴 0 会被
              // 窗口顶切掉（顶部阴影截断）；量化余量仍沉底
              alignment: Alignment(0, -1),
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Padding(
                padding: const EdgeInsets.only(top: kShadowPad),
                child: KeyedSubtree(
                key: _cardKey,
                child: AnimatedSize(
                  // 卡片尺寸动画（视觉过渡）：child 自然尺寸布局，
                  // AnimatedSize 只裁显不约束
                  duration: animDurOf(_animScale, 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    // 宽度治理（纯几何）：窄内容撑到下限、长单行在上限
                    // 换行——与字体无关
                    constraints: BoxConstraints(
                      minWidth: 360 * _fontScale,
                      maxWidth: 420 * _fontScale,
                    ),
                    child: KeyedSubtree(
                      key: _panelKey,
                      child: VoicePanel(
                      data: _data,
                      mouseHover: _mouseHover,
                      animScale: _animScale,
                      onHover: _onHoverRow,
                      onSelect: _selectCandidate,
                      panel: _panel,
                      onPanelSelect: _selectPanelCandidate,
                      fontScale: _fontScale,
                      sysFontFamily: _sysFontFamily,
                      ),
                    ),
                  ),
                ),
              ),
              ),
            ),
          ),
          ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 面板：按状态切换内容（全 MD3 官方组件）
// ---------------------------------------------------------------------------
class VoicePanel extends StatelessWidget {
  final SessionData data;
  final int mouseHover; // 鼠标悬停行（-1=无）
  final double animScale; // 全局动画速率挡位系数
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelect;
  final PanelData? panel; // IM 候选面板（null=无）
  final ValueChanged<int>? onPanelSelect;
  final double fontScale;
  final String? sysFontFamily;
  const VoicePanel({
    super.key,
    required this.data,
    required this.mouseHover,
    required this.animScale,
    required this.onHover,
    required this.onSelect,
    this.panel,
    this.onPanelSelect,
    this.fontScale = 1.0,
    this.sysFontFamily,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: const [
          // MD3 elevation：vision 复核建议加强对比（浅底上 0x33 偏淡）
          BoxShadow(color: Color(0x40202028), blurRadius: 10, spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        // 状态间内容过渡（录音指示器 → 结果 → 候选）：尺寸变化由外层
        // AnimatedSize 平滑衔接，这里补内容层的淡入淡出
        child: AnimatedSwitcher(
          duration: animDurOf(animScale, 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(
            // 会话三态（录音/结果/候选）是同一张卡片连续形变：
            // 只在 会话↔空闲 间做整体切换，状态间过渡由 _SessionBody
            // 内部的局部动画完成（文字本体不重建、不闪烁）
            key: ValueKey(data.state == UiState.idle ? 'idle' : 'session'),
            child: panel != null
                ? CandidatePanel(
                    data: panel!,
                    onSelect: onPanelSelect ?? (_) {},
                    animScale: animScale,
                    fontScale: fontScale,
                    sysFontFamily: sysFontFamily)
                : data.state == UiState.idle
                ? const _IdleBody()
                : _SessionBody(
                    data: data,
                    mouseHover: mouseHover,
                    animScale: animScale,
                    onHover: onHover,
                    onSelect: onSelect),
          ),
        ),
      ),
    );
  }
}

String _fmtMs(int ms) {
  final s = ms ~/ 1000;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

// —— 会话卡片（录音/结果/候选同一张卡片，连续形变）——
// 状态切换内容一次到位（徽标/tag/头部各自淡入淡出），尺寸变化全靠外层
// 唯一的 AnimatedSize 形变——新尺寸中途到达会重新定向（可打断），卡片
// 不重建、不分拍增长。行为自绘顶对齐（不用 ListTile：其多行内容的
// 垂直居中会让 padding-top 漂移）；头部固定槽，内容差异不再顶动下方行。
class _SessionBody extends StatelessWidget {
  final SessionData data;
  final int mouseHover; // 鼠标悬停行（-1=无）
  final double animScale; // 全局动画速率挡位系数
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelect;
  const _SessionBody({
    super.key,
    required this.data,
    required this.mouseHover,
    required this.animScale,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = data;
    final isCand = d.state == UiState.candidates;
    final items = d.candidates.take(2).toList();

    // 主文本行：录音=partial（bodyMedium，与候选原始版同款——过渡时
    // 样式/位置零跳变）；结果=final（titleMedium 平滑过渡）；候选=原始版
    final String mainText;
    final TextStyle mainStyle;
    switch (d.state) {
      case UiState.recording:
        mainText = d.partial;
        mainStyle = theme.textTheme.bodyMedium!;
      case UiState.result:
        mainText = d.resultText;
        mainStyle = theme.textTheme.titleMedium!;
      case UiState.candidates:
        mainText = items.length > 1
            ? items[1]
            : (items.isNotEmpty ? items[0] : '');
        mainStyle = theme.textTheme.bodyMedium!;
      case UiState.idle:
        mainText = '';
        mainStyle = theme.textTheme.bodyMedium!;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // —— 头部（min 高度托底 40：防止候选/结果的矮头部与选项间出现
        // 大空隙（曾设 56——录音头内容驱动不受影响，但矮头部下多出
        // ~30px 空当）；录音头的更高内容自由撑开，只托底不封顶）——
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: AnimatedSwitcher(
                duration: animDurOf(animScale, 180),
                child: switch (d.state) {
                  UiState.recording => Row(
                      key: const ValueKey('rec'),
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.mic,
                              color: cs.onErrorContainer, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_fmtMs(d.elapsedMs),
                                style: theme.textTheme.titleMedium?.copyWith(
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ])),
                            Text('正在听…',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ],
                    ),
                  UiState.result => Row(
                      key: const ValueKey('res'),
                      children: [
                        Icon(Icons.check_circle,
                            color: cs.primary, size: 18),
                        const SizedBox(width: 6),
                        Text('识别结果', style: theme.textTheme.labelMedium),
                      ],
                    ),
                  UiState.candidates => Row(
                      key: const ValueKey('cand'),
                      // 注意不能用 Spacer：Spacer(Expanded flex:1) 会与
                      // Flexible(hint) 平分剩余空间，提示恒被压到半宽再
                      // 省略截断（溢出真凶）。spaceBetween 让 hint 独占
                      // 剩余宽度
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome,
                                size: 14, color: cs.primary),
                            const SizedBox(width: 4),
                            Text('LLM 优化',
                                style: theme.textTheme.labelSmall),
                          ],
                        ),
                        Flexible(
                          child: Text(
                            'Enter=上屏 · Esc=取消',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  UiState.idle => const SizedBox.shrink(),
                },
              ),
            ),
          ),
        ),
        // —— 文本区（尺寸变化统一由外层 AnimatedSize 形变，单一可打断）——
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCand && items.isNotEmpty)
              TweenAnimationBuilder<double>(
                // 润色行淡入（候选内容一次到位，无分拍）
                tween: Tween(begin: 0, end: 1),
                duration: animDurOf(animScale, 220),
                builder: (_, v, child) => Opacity(opacity: v, child: child),
                child: _row(theme, cs,
                    index: 0,
                    text: items[0],
                    style: theme.textTheme.titleSmall!,
                    interactive: true,
                    tag: data.llmDummy ? 'Dummy 润色' : '润色版'),
              ),
            _row(theme, cs,
                index: 1,
                text: mainText.isEmpty ? ' ' : mainText,
                style: mainStyle,
                interactive: isCand && items.length > 1,
                tag: isCand && items.length > 1 ? '识别结果' : null),
          ],
        ),
        // —— 底部条（SizedBox 固定 6px 槽：minHeight:3 的指示器实际渲染
        // 偏高 ~4.5px，曾在录音态撑出底部溢出）——
        if (d.state == UiState.recording)
          const SizedBox(
              height: 6, child: LinearProgressIndicator(minHeight: 6)),
        if (d.state == UiState.result)
          SizedBox(
            height: 6,
            child: LinearProgressIndicator(
              minHeight: 6,
              value: 1.0,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
      ],
    );
  }

  // 数字徽标（圆形）：选中=实心主色、未选=描边——徽标编码选中态，
  // 双行文本几乎一样（占位润色只差句号）也能一眼看出选中了哪行
  Widget _badge(ColorScheme cs, int number, {required bool selected}) {
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? cs.primary : null,
        shape: BoxShape.circle,
        border: selected ? null : Border.all(color: cs.outlineVariant),
      ),
      child: Text('$number',
          style: TextStyle(
            fontSize: 11,
            color: selected ? cs.onPrimary : cs.onSurfaceVariant,
          )),
    );
  }

  // 自绘行（顶对齐）：徽标与文本都从行顶起排——多行内容不再有
  // ListTile 式的垂直居中漂移（padding-top 恒定）。非候选态徽标以
  // AnimatedOpacity 隐身占位（文本 x 位置恒定，候选态原位淡入）
  Widget _row(ThemeData theme, ColorScheme cs,
      {required int index,
      required String text,
      required TextStyle style,
      required bool interactive,
      String? tag}) {
    final hovered = interactive &&
        (mouseHover >= 0 ? mouseHover : data.hover) ==
            index;
    Widget core = AnimatedContainer(
      duration: animDurOf(animScale, 100),
      color: hovered ? cs.surfaceContainerHighest : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedOpacity(
              duration: animDurOf(animScale, 220),
              opacity: interactive ? 1 : 0,
              child: _badge(cs, index + 1, selected: hovered),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: animDurOf(animScale, 180),
                    style: style,
                    child: Text(text, softWrap: true),
                  ),
                  if (tag != null)
                    AnimatedOpacity(
                      duration: animDurOf(animScale, 220),
                      opacity: interactive ? 1 : 0,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          tag,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: index == 0
                                  ? cs.primary
                                  : cs.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!interactive) {
      return core;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      // 只挂 onHover（真实移动事件）：静止指针下弹出/布局变化合成的
      // onEnter 不选择——否则静止鼠标压住方向键选择
      onHover: (_) => onHover(index),
      onExit: (_) => onHover(-1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(index),
        child: core,
      ),
    );
  }
}

// —— 空闲态（理论上不可见；保留占位避免空帧）——

/// IM 候选面板（classicui 等价渲染）：水平/竖排候选列表，标签+文本+
/// 高亮+点击选择。视觉上与语音卡片共用 VoicePanel 容器（阴影/圆角）。
class CandidatePanel extends StatelessWidget {
  const CandidatePanel({
    super.key,
    required this.data,
    required this.onSelect,
    required this.animScale,
    this.fontScale = 1.0,
    this.sysFontFamily,
  });

  final PanelData data;
  final ValueChanged<int> onSelect;
  final double animScale;
  final double fontScale;
  final String? sysFontFamily;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fam = sysFontFamily ?? 'NotoSansSC';
    final cursor = data.cursor;
    final children = <Widget>[];
    for (int i = 0; i < data.candidates.length; i++) {
      final c = data.candidates[i];
      final selected = i == cursor;
      children.add(_candidateRow(cs, fam, c, i, selected));
    }
    if (data.isVertical) {
      return Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children);
    }
    return Wrap(spacing: 4, runSpacing: 2, children: children);
  }

  Widget _candidateRow(ColorScheme cs, String fam, PanelCandidate c, int index, bool selected) {
    return GestureDetector(
      onTap: () => onSelect(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(c.label,
              style: TextStyle(
                  fontFamily: fam,
                  fontSize: 13 * fontScale,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant)),
          const SizedBox(width: 3),
          Text(c.text,
              style: TextStyle(
                  fontFamily: fam,
                  fontSize: 14 * fontScale,
                  color: selected ? cs.onPrimaryContainer : cs.onSurface)),
          if (c.comment.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(c.comment,
                style: TextStyle(
                    fontFamily: fam,
                    fontSize: 11 * fontScale,
                    color: cs.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}

class _IdleBody extends StatelessWidget {
  const _IdleBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Icons.graphic_eq,
          color: Theme.of(context).colorScheme.outline, size: 28),
    );
  }
}
