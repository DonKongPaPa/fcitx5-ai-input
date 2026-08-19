// voice_ui：fcitx5-voiceinput 的浮窗 UI（MD3）
//
// 运行方式：Flutter 引擎进程内嵌入 fcitx5 addon（raw embedder API +
// kSoftware 软渲染），无 GTK 窗口/无独立进程——引擎把整窗帧直接交给
// addon 写入 zwp_input_popup_surface_v2 的 shm buffer。
//
// 尺寸策略（vision 反馈：与文本框等宽显"抢眼"，故收窄）：
//   宽度 clamp(TextPainter 实测内容宽, 280, 420)；录音态固定 280；
//   高度按状态：录音 104 / 结果按行数 / 候选按条数。
//   流式 partial 尾部优先（放不下截头加省略号，最新内容始终可见）。
//   实际窗口尺寸 = 卡片 + 四周 kShadowPad 阴影余量，变化时回发 resize。
//
// 协议（channel 'fcitx5/flutterui'，JSONMethodCodec）：
//   C++→Dart : MethodCall('update', {state, partial, elapsed_ms, final,
//                 timeout_ms, candidates, hover})
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

int lineCount(String text, TextStyle style, double maxWidth) {
  if (text.isEmpty) return 1;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  return tp.computeLineMetrics().length;
}

/// 尾部优先：maxLines 行内放不下时截头加省略号（流式最新内容优先可见）
String tailFit(String text, TextStyle style, double maxWidth, int maxLines) {
  if (text.isEmpty) return text;
  bool fits(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);
    return !tp.didExceedMaxLines;
  }

  if (fits(text)) return text;
  // 粗定位：按比例跳到后半段，再逐字精调
  var start = text.length ~/ 2;
  while (start < text.length && !fits('…${text.substring(start)}')) {
    start += 1;
  }
  return start >= text.length ? '…${text.substring(text.length ~/ 4)}' : '…${text.substring(start)}';
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

/// 面板尺寸决策：宽度 TextPainter 实测（280–420，随 fontScale 缩放），
/// 高度按状态。theme 必须与渲染主题同源（同字体族+字号缩放）——
/// 测量用默认字体而渲染用 SysFont 时宽度必然失准（用户实测候选头部
/// 提示溢出即此因）
Size panelSizeFor(ThemeData theme, SessionData d, double fontScale) {
  final minW = kMinW * fontScale, maxW = kMaxW * fontScale;
  switch (d.state) {
    case UiState.recording:
      return Size(280 * fontScale, 104 * fontScale);
    case UiState.result:
      {
        // 3 行放不下就加宽（步进 40*scale），仍放不下按 3 行截断
        var w = minW;
        var lines = lineCount(d.resultText, theme.textTheme.titleMedium!,
            w - 24 /* 左右 padding */);
        while (lines > 3 && w < maxW) {
          w += 40 * fontScale;
          lines =
              lineCount(d.resultText, theme.textTheme.titleMedium!, w - 24);
        }
        return Size(w, (60 + lines.clamp(1, 3) * 24) * fontScale);
      }
    case UiState.candidates:
      {
        // 最长候选一行实测（润色版另留 subtitle 余量；徽标 22 + 间距 16 + padding 24）
        final items = d.candidates.take(2).toList();
        double textW = 0;
        for (var i = 0; i < items.length; i++) {
          final style = i == 0
              ? theme.textTheme.titleSmall!
              : theme.textTheme.bodyMedium!;
          final need = measureWidth(items[i], style) + (i == 0 ? 24 : 0);
          if (need > textW) textW = need;
        }
        // 头部行也参与宽度决策（提示文字曾溢出）：图标 14 + 间距 4 +
        // "LLM 优化" + 提示文字 + 行 padding 24 + 弹性余量 24（实测
        // 余量 8 时 Row 可用宽仍差 ~16px，差 1-2 个字符触发省略）
        final labelStyle = theme.textTheme.labelSmall!;
        final headerW = 14 + 4 +
            measureWidth('LLM 优化', labelStyle) +
            measureWidth('数字/方向键选择 · Enter=上屏 · Esc=取消', labelStyle) +
            24 + 24;
        var w = (textW + 22 + 16 + 24 + 8).clamp(minW, maxW);
        if (w < headerW) {
          // 头部提示撑宽：允许超出常规 maxW（提示完整显示优先于宽度收敛）
          w = headerW.clamp(minW, maxW * 1.3);
        }
        return Size(w, (44 + items.length * 52 + 8 /* 首条 subtitle */) * fontScale);
      }
    case UiState.idle:
      return Size(280 * fontScale, 64 * fontScale);
  }
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
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: VoicePanel(
                    data: _data,
                    mouseHover: _mouseHover,
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
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelect;
  const VoicePanel({
    super.key,
    required this.data,
    required this.mouseHover,
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
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(
            key: ValueKey(data.state),
            child: switch (data.state) {
              UiState.recording => _RecordingBody(data: data),
              UiState.result => _ResultBody(data: data),
              UiState.candidates => _CandidatesBody(
                  data: data, mouseHover: mouseHover, onHover: onHover, onSelect: onSelect),
              UiState.idle => const _IdleBody(),
            },
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

// —— 录音态：麦克风 + 计时 + 流式 partial（尾部优先）+ 底部指示条 ——
class _RecordingBody extends StatelessWidget {
  final SessionData data;
  const _RecordingBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final partialStyle =
        theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.mic, color: cs.onErrorContainer, size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_fmtMs(data.elapsedMs),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: [FontFeature.tabularFigures()],
                      )),
                  Text('正在听…',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              // tailFit 用实际可用宽（字体缩放后不再写死 280）
              child: LayoutBuilder(builder: (ctx, c) {
                final shown =
                    tailFit(data.partial, partialStyle!, c.maxWidth, 2);
                return Text(
                  shown.isEmpty ? ' ' : shown,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: partialStyle,
                );
              }),
            ),
          ),
        ),
        const LinearProgressIndicator(minHeight: 3),
      ],
    );
  }
}

// —— 结果态（LLM 关）：文本 + 自动上屏倒计时条 ——
class _ResultBody extends StatelessWidget {
  final SessionData data;
  const _ResultBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: cs.primary, size: 18),
              const SizedBox(width: 6),
              Text('识别结果', style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                data.resultText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ),
        LinearProgressIndicator(
          minHeight: 3,
          value: 1.0,
          backgroundColor: cs.surfaceContainerHighest,
        ),
      ],
    );
  }
}

// —— 候选态（LLM 开）：润色版/原始版列表，鼠标/数字/方向键选择 ——
class _CandidatesBody extends StatelessWidget {
  final SessionData data;
  final int mouseHover;
  final ValueChanged<int> onHover;
  final ValueChanged<int> onSelect;
  const _CandidatesBody({
    required this.data,
    required this.mouseHover,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final items = data.candidates.take(2).toList();
    // 鼠标悬停优先显示，其次键盘方向键选择行
    final hover = mouseHover >= 0 ? mouseHover : data.hover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          // 注意不能用 Spacer：Spacer(Expanded flex:1) 会与 Flexible(hint)
          // 平分剩余空间，提示恒被压到半宽再省略截断（用户实测溢出的
          // 真凶）。spaceBetween 让 hint 独占全部剩余宽度
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 14, color: cs.primary),
                  const SizedBox(width: 4),
                  Text('LLM 优化', style: theme.textTheme.labelSmall),
                ],
              ),
              Flexible(
                child: Text(
                  '数字/方向键选择 · Enter=上屏 · Esc=取消',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < items.length; i++)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => onHover(i),
            onExit: (_) => onHover(-1),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                color: i == hover ? cs.surfaceContainerHighest : null,
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == 0 ? cs.primary : cs.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Text('${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          color: i == 0 ? cs.onPrimary : cs.onSurfaceVariant,
                        )),
                  ),
                  title: Text(
                    items[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: i == 0 ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium,
                  ),
                  subtitle: i == 0
                      ? Text('润色版',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.primary))
                      : null,
                ),
              ),
            ),
          ),
      ],
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
