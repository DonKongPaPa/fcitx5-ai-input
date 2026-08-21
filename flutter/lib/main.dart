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
/// theme 必须与渲染主题同源（同字体族+字号缩放）：测量用默认字体而
/// 渲染用 SysFont 时宽度必然失准（候选头部提示溢出即此因）
Size panelSizeFor(ThemeData theme, SessionData d, double fontScale) {
  final minW = 360 * fontScale, maxW = kMaxW * fontScale;
  if (d.state == UiState.idle) {
    return Size(280 * fontScale, 64 * fontScale);
  }
  // 行内容：录音=[partial(bodyMedium)]；结果=[final(titleMedium)]；候选=
  // [润色(titleSmall), 原始(bodyMedium)]。录音末尾 partial 即原始候选
  // 文本——宽度与行位置在录音→候选过渡时天然衔接
  final rows = <(String, TextStyle)>[];
  switch (d.state) {
    case UiState.recording:
      rows.add((d.partial, theme.textTheme.bodyMedium!));
    case UiState.result:
      rows.add((d.resultText, theme.textTheme.titleMedium!));
    case UiState.candidates:
      final items = d.candidates.take(2).toList();
      if (items.isNotEmpty) {
        rows.add((items[0], theme.textTheme.titleSmall!));
      }
      if (items.length > 1) {
        rows.add((items[1], theme.textTheme.bodyMedium!));
      }
    case UiState.idle:
      break;
  }
  // 宽度：最长行单行实测（首行另留 subtitle 余量 24；徽标 22+间距 16+
  // padding 24+8 同候选既有公式），clamp(360, 420)×fontScale
  double textW = 0;
  for (var i = 0; i < rows.length; i++) {
    final need = measureWidth(rows[i].$1, rows[i].$2) + (i == 0 ? 24 : 0);
    if (need > textW) textW = need;
  }
  final w = (textW + 22 + 16 + 24 + 8).clamp(minW, maxW);
  // 高度：头部 44 + 行基数 52/行 + subtitle 余量 8 + 换行增量 + 底部条
  //（录音=指示条、结果=倒计时条，均 3px）。换行测量按 0.95×可用宽
  //（悲观方向）：可变字体 ±5% 偏差只会让测量行数 ≥ 渲染行数，不溢出
  final textAvail = (w - 12 * 2 - 20 - 16) * 0.95;
  double extra = 0;
  for (final r in rows) {
    final block = textBlockHeight(r.$1, r.$2, textAvail);
    final single = textBlockHeight(r.$1, r.$2, double.infinity);
    if (block > single) extra += block - single;
  }
  final bar = (d.state == UiState.recording || d.state == UiState.result)
      ? 3.0
      : 0.0;
  return Size(w, (44 + rows.length * 52 + 8) * fontScale + extra + bar);
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
// 头部随状态交叉淡化；主文本行全程原位：录音=流式 partial 完整软换行
//（不限行数、无省略、无滚动），候选态它原位变成「原始版」行——徽标
// 淡入、润色行在上方展开推入；底部条录音=指示条、结果=倒计时条。
class _SessionBody extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isCand = data.state == UiState.candidates;
    final items = data.candidates.take(2).toList();

    // 主文本行：录音=partial（bodyMedium，与候选原始版同款——过渡时
    // 样式/位置零跳变）；结果=final（titleMedium，AnimatedDefaultText
    // Style 平滑过渡）；候选=原始版
    final String mainText;
    final TextStyle mainStyle;
    switch (data.state) {
      case UiState.recording:
        mainText = data.partial;
        mainStyle = theme.textTheme.bodyMedium!;
      case UiState.result:
        mainText = data.resultText;
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
        // —— 头部（交叉淡化）——
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: AnimatedSwitcher(
            duration: animDurOf(animScale, 180),
            child: switch (data.state) {
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
                        Text(_fmtMs(data.elapsedMs),
                            style: theme.textTheme.titleMedium?.copyWith(
                                fontFeatures: [FontFeature.tabularFigures()])),
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
                    Icon(Icons.check_circle, color: cs.primary, size: 18),
                    const SizedBox(width: 6),
                    Text('识别结果', style: theme.textTheme.labelMedium),
                  ],
                ),
              UiState.candidates => Row(
                  key: const ValueKey('cand'),
                  // 注意不能用 Spacer：Spacer(Expanded flex:1) 会与
                  // Flexible(hint) 平分剩余空间，提示恒被压到半宽再省略
                  // 截断（溢出真凶）。spaceBetween 让 hint 独占剩余宽度
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome,
                            size: 14, color: cs.primary),
                        const SizedBox(width: 4),
                        Text('LLM 优化', style: theme.textTheme.labelSmall),
                      ],
                    ),
                    Flexible(
                      child: Text(
                        // 提示内容刻意精简：完整版在可变字体+窄卡下会触
                        // 发行溢出（RenderFlex overflowed）。短版在最小
                        // 卡宽内留足双倍余量
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
        // —— 文本区（AnimatedSize 平滑长高/推入润色行）——
        AnimatedSize(
          duration: animDurOf(animScale, 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCand && items.isNotEmpty)
                TweenAnimationBuilder<double>(
                  // 润色行入场：淡入（推展由外层 AnimatedSize 完成）
                  tween: Tween(begin: 0, end: 1),
                  duration: animDurOf(animScale, 220),
                  builder: (_, v, child) => Opacity(opacity: v, child: child),
                  child: _row(theme, cs,
                      index: 0,
                      text: items[0],
                      style: theme.textTheme.titleSmall!,
                      interactive: true),
                ),
              _row(theme, cs,
                  index: 1,
                  text: mainText.isEmpty ? ' ' : mainText,
                  style: mainStyle,
                  interactive: isCand && items.length > 1),
            ],
          ),
        ),
        // —— 底部条 ——
        if (data.state == UiState.recording)
          const LinearProgressIndicator(minHeight: 3),
        if (data.state == UiState.result)
          LinearProgressIndicator(
            minHeight: 3,
            value: 1.0,
            backgroundColor: cs.surfaceContainerHighest,
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

  // 统一行：几何与候选行完全同构——录音/结果态徽标以 AnimatedOpacity
  // 隐身占位（文本 x 位置在状态过渡间恒定，候选态原位淡入）；结果态的
  // 字号变化经 AnimatedDefaultTextStyle 平滑过渡
  Widget _row(ThemeData theme, ColorScheme cs,
      {required int index,
      required String text,
      required TextStyle style,
      required bool interactive}) {
    final hovered = interactive &&
        (mouseHover >= 0 ? mouseHover : data.hover) == index;
    Widget core = AnimatedContainer(
      duration: animDurOf(animScale, 100),
      color: hovered ? cs.surfaceContainerHighest : null,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: AnimatedOpacity(
          duration: animDurOf(animScale, 220),
          opacity: interactive ? 1 : 0,
          child: _badge(cs, index + 1, primary: index == 0),
        ),
        title: AnimatedDefaultTextStyle(
          duration: animDurOf(animScale, 180),
          style: style,
          child: Text(text, softWrap: true),
        ),
        subtitle: (interactive && index == 0)
            ? Text('润色版',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.primary))
            : null,
      ),
    );
    if (!interactive) {
      return core;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(index),
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
