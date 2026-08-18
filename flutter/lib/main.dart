// voice_ui：fcitx5-voiceinput 的浮窗 UI（MD3）
//
// 运行方式：由 addon 拉起的独立进程，窗口开在专用无头合成器（weston
// headless）上；本进程不直接上屏——用 RepaintBoundary.toImage 快照出 RGBA
// 帧，经 TCP 桥发给 addon，addon 写入 zwp_input_popup_surface_v2 的 shm
// buffer（帧尺寸变化时 addon 自动重建池）。
//
// 尺寸策略（vision 反馈：与文本框等宽显"抢眼"，故收窄）：
//   宽度 clamp(TextPainter 实测内容宽, 280, 420)；录音态固定 280；
//   高度按状态：录音 104 / 结果按行数 / 候选按条数。
//   流式 partial 尾部优先（放不下截头加省略号，最新内容始终可见）。
//
// 协议（TCP，行式 JSON + 二进制帧）：
//   addon→ui : {"type":"state","state":"recording","partial":"..","elapsed_ms":0}
//              {"type":"state","state":"candidates","final":"..","candidates":[".."]}
//              {"type":"state","state":"result","final":"..","timeout_ms":1500}
//              {"type":"state","state":"idle"}
//   ui→addon : {"type":"frame","w":W,"h":H,"len":N}\n + N 字节 RGBA
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const double kMinW = 280;
const double kMaxW = 420;

void main() {
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
// TCP 桥（断线自动重连）
// ---------------------------------------------------------------------------
class Bridge {
  Socket? _sock;
  StreamSubscription? _sub;
  Timer? _retry;
  bool _closing = false;
  final void Function(Map<String, dynamic>) onMessage;
  final void Function() onConnected;

  Bridge({required this.onMessage, required this.onConnected});

  Future<void> start() async {
    final host = Platform.environment['VOICEINPUT_BRIDGE_HOST'] ?? '127.0.0.1';
    final port =
        int.parse(Platform.environment['VOICEINPUT_BRIDGE_PORT'] ?? '27191');
    try {
      _sock = await Socket.connect(host, port,
          timeout: const Duration(seconds: 3));
      onConnected();
      _sub = _sock!.listen(_onData,
          onError: (_) => _reconnect(), onDone: _reconnect, cancelOnError: true);
    } catch (_) {
      _reconnect();
    }
  }

  void _reconnect() {
    if (_closing) return;
    _sub?.cancel();
    _sock?.destroy();
    _sock = null;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 1), start);
  }

  // 行式 JSON：自行缓冲按 \n 切分（不用 transform，避免类型协变问题）
  final BytesBuilder _buf = BytesBuilder(copy: true);
  void _onData(Uint8List chunk) {
    _buf.add(chunk);
    var data = _buf.takeBytes();
    while (true) {
      final idx = data.indexOf(0x0a);
      if (idx < 0) {
        _buf.add(data);
        break;
      }
      final line = utf8.decode(data.sublist(0, idx), allowMalformed: true);
      data = data.sublist(idx + 1);
      _onLine(line);
    }
  }

  void _onLine(String line) {
    if (line.isEmpty) return;
    try {
      onMessage(jsonDecode(line) as Map<String, dynamic>);
    } catch (_) {}
  }

  void sendFrame(Uint8List rgba, int w, int h) {
    final s = _sock;
    if (s == null) return;
    final hdr =
        utf8.encode('{"type":"frame","w":$w,"h":$h,"len":${rgba.length}}\n');
    s.add(hdr);
    s.add(rgba);
  }

  void dispose() {
    _closing = true;
    _retry?.cancel();
    _sub?.cancel();
    _sock?.destroy();
  }
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
  final int hover; // 鼠标悬停候选行（-1=无；niri seat 级指针路由）
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      ),
      home: const VoiceUiHome(),
    );
  }
}

/// 面板尺寸决策：宽度 TextPainter 实测（280–420），高度按状态
Size panelSizeFor(ThemeData theme, SessionData d) {
  switch (d.state) {
    case UiState.recording:
      return const Size(280, 104);
    case UiState.result:
      {
        // 3 行放不下就加宽（步进 40），仍放不下按 3 行截断
        var w = kMinW;
        var lines = lineCount(d.resultText, theme.textTheme.titleMedium!,
            w - 24 /* 左右 padding */);
        while (lines > 3 && w < kMaxW) {
          w += 40;
          lines =
              lineCount(d.resultText, theme.textTheme.titleMedium!, w - 24);
        }
        return Size(w, 60 + lines.clamp(1, 3) * 24);
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
        final w = (textW + 22 + 16 + 24 + 8).clamp(kMinW, kMaxW);
        return Size(w, 44 + items.length * 52 + 8 /* 首条 subtitle */);
      }
    case UiState.idle:
      return const Size(280, 64);
  }
}

class VoiceUiHome extends StatefulWidget {
  const VoiceUiHome({super.key});

  @override
  State<VoiceUiHome> createState() => _VoiceUiHomeState();
}

class _VoiceUiHomeState extends State<VoiceUiHome> {
  final GlobalKey _rbKey = GlobalKey();
  late final Bridge _bridge;
  SessionData _data = const SessionData();
  Timer? _ticker;
  int _localElapsed = 0;

  @override
  void initState() {
    super.initState();
    _bridge = Bridge(onMessage: _onMessage, onConnected: () {});
    _bridge.start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bridge.dispose();
    super.dispose();
  }

  void _onMessage(Map<String, dynamic> msg) {
    if (msg['type'] != 'state') return;
    switch (msg['state'] as String? ?? 'idle') {
      case 'recording':
        _localElapsed = (msg['elapsed_ms'] as int? ?? 0);
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
          timeoutMs: msg['timeout_ms'] as int? ?? 1500,
        ));
        break;
      case 'candidates':
        _ticker?.cancel();
        _update(SessionData(
          state: UiState.candidates,
          resultText: msg['final'] as String? ?? '',
          candidates: (msg['candidates'] as List?)?.cast<String>() ?? const [],
          hover: msg['hover'] as int? ?? -1,
        ));
        break;
      default:
        _ticker?.cancel();
        _update(const SessionData());
    }
  }

  void _update(SessionData d) {
    setState(() => _data = d);
    _scheduleSnapshot();
  }

  // 快照：帧渲染完成后截 RepaintBoundary → RGBA → 发 addon（尺寸取实际值）
  int _frameCount = 0;
  void _scheduleSnapshot() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ro = _rbKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.attached) return;
      final w = ro.size.width.round();
      final h = ro.size.height.round();
      final image = await ro.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bytes != null && w > 0 && h > 0) {
        _bridge.sendFrame(bytes.buffer.asUint8List(), w, h);
        // 容器内可观测性：每 10 帧打一行（release 下 print 仍输出）
        _frameCount++;
        if (_frameCount == 1 || _frameCount % 10 == 0) {
          // ignore: avoid_print
          print('ui-frame #$_frameCount ${w}x$h ${_data.state.name}');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = panelSizeFor(Theme.of(context), _data);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: RepaintBoundary(
          key: _rbKey,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VoicePanel(data: _data),
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
  const VoicePanel({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: switch (data.state) {
          UiState.recording => _RecordingBody(data: data),
          UiState.result => _ResultBody(data: data),
          UiState.candidates => _CandidatesBody(data: data),
          UiState.idle => _IdleBody(),
        },
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
    final shown = tailFit(
        data.partial, partialStyle!, 280 - 24 /* 左右 padding */, 2);
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
                        fontFeatures: [ui.FontFeature.tabularFigures()],
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
              child: Text(
                shown.isEmpty ? ' ' : shown,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: partialStyle,
              ),
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

// —— 候选态（LLM 开）：润色版/原始版列表，数字键选择 ——
class _CandidatesBody extends StatelessWidget {
  final SessionData data;
  const _CandidatesBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final items = data.candidates.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: cs.primary),
              const SizedBox(width: 4),
              Text('LLM 优化', style: theme.textTheme.labelSmall),
              const Spacer(),
              Text('数字选择 · Enter=1 · Esc=取消',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        for (var i = 0; i < items.length; i++)
          // hover 行高亮（niri seat 级指针路由）
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            color: i == data.hover ? cs.surfaceContainerHighest : null,
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
