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
//              invokeMethod('selectCandidate', {index})
//              invokeMethod('hoverChanged', {row}) // 测试观测用
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double kMinW = 280;
const double kMaxW = 420;
// 卡片阴影余量：快照区比卡片四周各大这么多（BoxShadow blur10+spread1
// 超出边界 ~11px）；指针坐标是含余量的表面局部坐标，Padding 天然吸收
const double kShadowPad = 12;

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
  runApp(const VoiceUiApp());
}

// ---------------------------------------------------------------------------
// 文本测量（TextPainter，官方 API）
// ---------------------------------------------------------------------------
double measureWidth(String text, TextStyle style) {
  if (text.isEmpty) return 0;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return tp.width;
}

/// 多行文本块高：按可用宽排版后的总像素高（换行的高度测量）
double textBlockHeight(String text, TextStyle style, double maxWidth) {
  if (text.isEmpty) return 0;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  return tp.height;
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
  const SessionData({
    this.state = UiState.idle,
    this.partial = '',
    this.resultText = '',
    this.candidates = const [],
    this.elapsedMs = 0,
    this.timeoutMs = 1500,
    this.hover = -1,
  });
}

// ---------------------------------------------------------------------------
// App 根
// ---------------------------------------------------------------------------
class VoiceUiApp extends StatelessWidget {
  const VoiceUiApp({super.key});

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
      home: const VoiceUiHome(),
    );
  }
}

/// 面板尺寸决策（会话三态同一张卡片同一公式——状态间过渡零跳变）。
/// 行为自绘（顶对齐、显式 padding），测量与布局一一对应；头部固定
/// 44·fontScale 槽位（内容差异不再影响下方行位置）。theme 必须与渲染
/// 主题同源（同字体族+字号缩放）
// 头部固定槽高度（会话三态共用）：录音头最高（计时两行文字随字号
// 缩放，16pt 下实测超出 44·fs 常数曾撑出 4.5px 溢出），按其实测内容
// 取高；布局与尺寸公式共用本函数
double sessionHeaderSlotH(ThemeData theme) {
  final titleH =
      textBlockHeight('00:00', theme.textTheme.titleMedium!, double.infinity);
  final labelH =
      textBlockHeight('正在听…', theme.textTheme.labelSmall!, double.infinity);
  final content = titleH + labelH > 36 ? titleH + labelH : 36.0;
  return 8 + content + 2;
}

Size panelSizeFor(ThemeData theme, SessionData d, double fontScale) {
  final minW = 360 * fontScale, maxW = kMaxW * fontScale;
  if (d.state == UiState.idle) {
    return Size(280 * fontScale, 64 * fontScale);
  }
  // 行内容（text, style, tag）：录音=[partial]；结果=[final]；候选=
  // [润色(带 tag), 原始(带 tag「识别结果」)]。录音末尾 partial 即原始
  // 候选文本——过渡时宽度与行位置天然衔接
  final rows = <(String, TextStyle, String?)>[];
  switch (d.state) {
    case UiState.recording:
      rows.add((d.partial, theme.textTheme.bodyMedium!, null));
    case UiState.result:
      rows.add((d.resultText, theme.textTheme.titleMedium!, null));
    case UiState.candidates:
      final items = d.candidates.take(2).toList();
      if (items.isNotEmpty) {
        rows.add((items[0], theme.textTheme.titleSmall!, '润色版'));
      }
      if (items.length > 1) {
        rows.add((items[1], theme.textTheme.bodyMedium!, '识别结果'));
      }
    case UiState.idle:
      break;
  }
  // 宽度：最长行单行实测（徽标 20+间距 8+左右 padding 24+余量 8），
  // clamp(360, 420)×fontScale
  double textW = 0;
  for (final r in rows) {
    final need = measureWidth(r.$1, r.$2);
    if (need > textW) textW = need;
  }
  final w = (textW + 20 + 8 + 24 + 8).clamp(minW, maxW);
  // 高度 = 头部槽 44·fs + Σ 行（v-pad 12·fs + max(徽标 20, 文本块高) +
  // tag 行高）+ 底部条。换行测量按 0.95×可用宽（悲观方向）：可变字体
  // ±5% 偏差只会让测量行数 ≥ 渲染行数，不溢出
  final textAvail = (w - 12 * 2 - 20 - 8) * 0.95;
  final tagStyle = theme.textTheme.labelSmall!;
  double h = sessionHeaderSlotH(theme);
  for (final r in rows) {
    final block = textBlockHeight(
        r.$1.isEmpty ? ' ' : r.$1, r.$2, textAvail);
    h += 12 * fontScale + (20 * fontScale > block ? 20 * fontScale : block);
    final tag = r.$3;
    if (tag != null) {
      h += textBlockHeight(tag, tagStyle, double.infinity) + 2;
    }
  }
  final bar = (d.state == UiState.recording || d.state == UiState.result)
      ? 6.0
      : 0.0;
  return Size(w, h + bar);
}

class VoiceUiHome extends StatefulWidget {
  const VoiceUiHome({super.key});

  @override
  State<VoiceUiHome> createState() => _VoiceUiHomeState();
}

class _VoiceUiHomeState extends State<VoiceUiHome> {
  // GTK runner 下跑（开发调试）时无 C++ 对端，channel 调用静默失败
  static const _ch = MethodChannel('fcitx5/flutterui', JSONMethodCodec());
  SessionData _data = const SessionData();
  Timer? _ticker;
  int _localElapsed = 0;
  String? _sysFontFamily; // classicui 跟随字体（FontLoader 注册后启用）
  double _fontScale = 1.0; // size/12 基准
  double _animScale = kDefaultAnimScale; // 动画速率挡位系数
  ThemeData? _renderTheme; // build 捕获的规范化渲染主题（测量同源用）
  int _mouseHover = -1; // 鼠标悬停行（本地状态；键盘选择走 data.hover）
  Size _lastReported = Size.zero;

  void _invoke(String method, [dynamic args]) {
    _ch.invokeMethod(method, args).catchError((_) => null);
  }

  @override
  void initState() {
    super.initState();
    _ch.setMethodCallHandler(_onCall);
    _invoke('ready');
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // C++→Dart：update{...}（字段同旧 TCP 协议）
  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'update') return null;
    final msg = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    // 动画挡位随任意消息到达（update/font 均携带）
    final animScale = (msg['anim'] as num?)?.toDouble();
    if (animScale != null) _animScale = animScale;
    // 字体跟随（C++ fontconfig 解析后下发）
    if (msg['state'] == 'font') {
      await _applyFont(msg['path'] as String? ?? '',
          (msg['size'] as num?)?.toDouble() ?? 12);
      return null;
    }
    switch (msg['state'] as String? ?? 'idle') {
      case 'recording':
        _localElapsed = (msg['elapsed_ms'] as num?)?.toInt() ?? 0;
        var partial = msg['partial'] as String? ?? '';
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
      case 'result':
        _ticker?.cancel();
        _update(SessionData(
          state: UiState.result,
          resultText: msg['final'] as String? ?? '',
          timeoutMs: (msg['timeout_ms'] as num?)?.toInt() ?? 1500,
        ));
        break;
      case 'candidates':
        _ticker?.cancel();
        _mouseHover = -1;
        _update(SessionData(
          state: UiState.candidates,
          resultText: msg['final'] as String? ?? '',
          candidates: (msg['candidates'] as List?)?.cast<String>() ?? const [],
          hover: (msg['hover'] as num?)?.toInt() ?? -1,
        ));
        break;
      default:
        _ticker?.cancel();
        _mouseHover = -1;
        _update(const SessionData());
    }
    return null;
  }

  void _update(SessionData d) {
    setState(() => _data = d);
    // 窗口尺寸 = 卡片（已按当前字体测量）+ 阴影余量，变化即上报
    // （C++ 侧据此更新引擎 metrics → 重排 → 下一帧即新尺寸，popup 池随帧自动重建）
    final size = panelSizeFor(_measureTheme(), d, _fontScale);
    final win = Size(size.width + kShadowPad * 2, size.height + kShadowPad * 2);
    if (win != _lastReported) {
      _lastReported = win;
      _invoke('resize', {'w': win.width.round(), 'h': win.height.round()});
    }
  }

  /// 测量主题：与 build 的渲染主题同源（同字体族 + 同字号缩放），否则
  /// TextPainter 实测宽与实际渲染宽失配 → 溢出。注意：直接对裸
  /// ThemeData().textTheme.apply(fontSizeFactor≠1) 会命中框架断言
  /// （部分样式 fontSize 为 null）——Theme.of 返回的规范化主题才安全，
  /// 故 build 时捕获、此处复用；兜底主题因子恒 1（断言允许）
  ThemeData _measureTheme() {
    if (_renderTheme != null) return _renderTheme!;
    final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansSC',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: brightness),
    );
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
      setState(() => _mouseHover = row);
      _invoke('hoverChanged', {'row': row});
    }
  }

  void _selectCandidate(int index) {
    _invoke('selectCandidate', {'index': index});
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
    _renderTheme = theme; // 测量同源（_measureTheme 复用）
    // 测量与渲染同源：size 已含 fontScale，不再二次放大
    final size = panelSizeFor(theme, _data, _fontScale);
    // 非状态变化路径（如字体热更）的尺寸上报兜底：后置帧上报
    final win = Size(size.width + kShadowPad * 2, size.height + kShadowPad * 2);
    if (win != _lastReported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || win == _lastReported) return;
        _lastReported = win;
        _invoke('resize', {'w': win.width.round(), 'h': win.height.round()});
      });
    }
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: SizedBox(
            width: size.width + kShadowPad * 2,
            height: size.height + kShadowPad * 2,
            child: Padding(
              padding: const EdgeInsets.all(kShadowPad),
              child: AnimatedSize(
                // 状态切换的尺寸过渡：窗口尺寸直接跳到目标态（透明区无感），
                // 卡片本体在窗口内平滑伸缩，避免逐帧 resize 的反馈循环
                duration: animDurOf(_animScale, 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: VoicePanel(
                    data: _data,
                    mouseHover: _mouseHover,
                    animScale: _animScale,
                    onHover: _onHoverRow,
                    onSelect: _selectCandidate,
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
  const VoicePanel({
    super.key,
    required this.data,
    required this.mouseHover,
    required this.animScale,
    required this.onHover,
    required this.onSelect,
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
            child: data.state == UiState.idle
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
// 录音→候选分两拍：先主文本行原位冻结成「识别结果」候选行（徽标+tag
// 淡入），LLM 润色行延后入场——对应真实 LLM 的异步时序（识别输出完毕
// 的结果固定在位，优化步骤再排序插入）。行为自绘顶对齐（不用
// ListTile：其多行内容的垂直居中会让 padding-top 漂移）；头部固定槽，
// 内容差异不再顶动下方行。
class _SessionBody extends StatefulWidget {
  final SessionData data;
  final int mouseHover; // 鼠标悬停行（-1=无）
  final double animScale; // 全局动画速率挡位系数
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelect;
  const _SessionBody({
    required this.data,
    required this.mouseHover,
    required this.animScale,
    required this.onHover,
    required this.onSelect,
  });

  @override
  State<_SessionBody> createState() => _SessionBodyState();
}

class _SessionBodyState extends State<_SessionBody> {
  bool _showPolish = false; // 润色行是否入场（录音→候选的第二拍）
  Timer? _polishTimer;

  @override
  void didUpdateWidget(covariant _SessionBody old) {
    super.didUpdateWidget(old);
    final d = widget.data.state;
    if (d == UiState.candidates && old.data.state == UiState.recording) {
      // 第一拍立刻生效（徽标+识别结果 tag）；第二拍延后
      _showPolish = false;
      _polishTimer?.cancel();
      _polishTimer = Timer(animDurOf(widget.animScale, 500), () {
        if (mounted && widget.data.state == UiState.candidates) {
          setState(() => _showPolish = true);
        }
      });
    } else if (d == UiState.candidates) {
      _showPolish = true; // 非录音直入候选（如重触发）：无分拍
    }
  }

  @override
  void dispose() {
    _polishTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = widget.data;
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
        // —— 头部（固定 44·fs 槽：内容交叉淡化，高度恒定不顶动行）——
        SizedBox(
          height: sessionHeaderSlotH(theme),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: AnimatedSwitcher(
                duration: animDurOf(widget.animScale, 180),
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
        // —— 文本区（AnimatedSize 平滑长高/推入润色行）——
        AnimatedSize(
          duration: animDurOf(widget.animScale, 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCand && items.isNotEmpty && _showPolish)
                TweenAnimationBuilder<double>(
                  // 润色行入场（第二拍）：淡入，推展由外层 AnimatedSize
                  tween: Tween(begin: 0, end: 1),
                  duration: animDurOf(widget.animScale, 220),
                  builder: (_, v, child) => Opacity(opacity: v, child: child),
                  child: _row(theme, cs,
                      index: 0,
                      text: items[0],
                      style: theme.textTheme.titleSmall!,
                      interactive: true,
                      tag: '润色版'),
                ),
              _row(theme, cs,
                  index: 1,
                  text: mainText.isEmpty ? ' ' : mainText,
                  style: mainStyle,
                  interactive: isCand && items.length > 1,
                  tag: isCand && items.length > 1 ? '识别结果' : null),
            ],
          ),
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

  // 数字徽标（圆形）
  Widget _badge(ColorScheme cs, int number, {required bool primary}) {
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primary ? cs.primary : cs.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Text('$number',
          style: TextStyle(
            fontSize: 11,
            color: primary ? cs.onPrimary : cs.onSurfaceVariant,
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
        (widget.mouseHover >= 0 ? widget.mouseHover : widget.data.hover) ==
            index;
    Widget core = AnimatedContainer(
      duration: animDurOf(widget.animScale, 100),
      color: hovered ? cs.surfaceContainerHighest : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedOpacity(
              duration: animDurOf(widget.animScale, 220),
              opacity: interactive ? 1 : 0,
              child: _badge(cs, index + 1, primary: index == 0),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: animDurOf(widget.animScale, 180),
                    style: style,
                    child: Text(text, softWrap: true),
                  ),
                  if (tag != null)
                    AnimatedOpacity(
                      duration: animDurOf(widget.animScale, 220),
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
      onEnter: (_) => widget.onHover(index),
      onExit: (_) => widget.onHover(-1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelect(index),
        child: core,
      ),
    );
  }
}

// —— 空闲态（理论上不可见；保留占位避免空帧）——
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
