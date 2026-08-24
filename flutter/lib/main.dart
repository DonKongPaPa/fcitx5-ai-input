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

const double kMaxW = 420;
// 卡片阴影余量：快照区比卡片四周各大这么多（BoxShadow blur10+spread1
// 超出边界 ~11px）；指针坐标是含余量的表面局部坐标，Padding 天然吸收
const double kShadowPad = 12;
// 增长余量：内容自然长高的当前帧先落在透明余量里，resize 下一帧跟上
const double kGrowthSlack = 20;

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
  int _mouseHover = -1; // 鼠标悬停行（本地状态；键盘选择走 data.hover）
  Size _lastReported = Size.zero;
  final GlobalKey _cardKey = GlobalKey(); // 卡片实际尺寸回读（布局后）

  void _invoke(String method, [dynamic args]) {
    _ch.invokeMethod(method, args).catchError((_) => null);
  }

  @override
  void initState() {
    super.initState();
    _ch.setMethodCallHandler(_onCall);
    _invoke('ready');
    // 持久帧回调：每帧布局完成后回读卡片尺寸、变化即上报。不能挂在
    // build 的 post-frame 上——AnimatedSize 等动画只在 render 层逐帧
    // 进行不触发 build，最终尺寸曾因此漏报（展开形态被旧窗口裁掉，
    // 直到下一次 setState 才"神奇恢复"）
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      if (!mounted) return;
      final ro = _cardKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        _reportSize(ro.size);
      }
    });
  }

  void _reportSize(Size card) {
    // 尺寸量化到 32px 步进（向上取整）：动画期间卡片逐帧生长，若逐帧
    // 上报，C++ 每帧重建 shm 池+metrics 重排——流式期进度条掉帧的主因。
    // 量化后窗口始终 ≥ 卡片（余量吸收差值，透明不可见），重建次数降一个
    // 数量级
    const q = 32.0;
    final win = Size(
      ((card.width + (kShadowPad + kGrowthSlack) * 2) / q).ceilToDouble() * q,
      ((card.height + (kShadowPad + kGrowthSlack) * 2) / q).ceilToDouble() * q,
    );
    if (win != _lastReported) {
      _lastReported = win;
      _invoke('resize', {'w': win.width.ceil(), 'h': win.height.ceil()});
    }
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
        final int msgHover = (msg['hover'] as num?)?.toInt() ?? -1;
        // hover 值 ≠ 本地悬停 = 键盘改了选择（或新会话）→ 悬停让位，
        // 方向键接管显示；鼠标再次移动经 onHover 重新接管
        _mouseHover = msgHover == _mouseHover ? _mouseHover : -1;
        _update(SessionData(
          state: UiState.candidates,
          resultText: msg['final'] as String? ?? '',
          candidates: (msg['candidates'] as List?)?.cast<String>() ?? const [],
          hover: msgHover,
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
              alignment: Alignment.center,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
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
      // 只挂 onHover（真实移动事件）：静止指针下弹出/布局变化合成的
      // onEnter 不选择——否则静止鼠标压住方向键选择
      onHover: (_) => widget.onHover(index),
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
