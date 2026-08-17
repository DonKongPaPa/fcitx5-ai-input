// voice_ui：fcitx5-voiceinput 的浮窗 UI（MD3）
//
// 运行方式：由 addon 拉起的独立进程，窗口开在专用无头合成器（cage2）上；
// 本进程不直接上屏——用 RepaintBoundary.toImage 快照出 RGBA 帧，
// 经 TCP 桥发给 addon，addon 写入 zwp_input_popup_surface_v2 的 shm buffer。
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

const double kUiWidth = 360;
const double kUiHeight = 200;

void main() {
  runApp(const VoiceUiApp());
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

  void _reconnect() {
    if (_closing) return;
    _sub?.cancel();
    _sock?.destroy();
    _sock = null;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 1), start);
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
  final String partial; // 流式中间结果（灰字实时显示）
  final String resultText; // 最终文本
  final List<String> candidates; // 候选（首个=润色版）
  final int elapsedMs; // 录音计时
  final int timeoutMs; // result 停留时长（倒计时条）
  const SessionData({
    this.state = UiState.idle,
    this.partial = '',
    this.resultText = '',
    this.candidates = const [],
    this.elapsedMs = 0,
    this.timeoutMs = 1500,
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

  // 快照：帧渲染完成后截 RepaintBoundary → RGBA → 发 addon
  int _frameCount = 0;
  void _scheduleSnapshot() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ro = _rbKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      final image = await ro.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bytes != null) {
        _bridge.sendFrame(
            bytes.buffer.asUint8List(), kUiWidth.toInt(), kUiHeight.toInt());
        // 容器内可观测性：每 10 帧打一行（release 下 print 仍输出）
        _frameCount++;
        if (_frameCount == 1 || _frameCount % 10 == 0) {
          // ignore: avoid_print
          print('ui-frame #$_frameCount state=${_data.state.name}');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: RepaintBoundary(
          key: _rbKey,
          child: SizedBox(
            width: kUiWidth,
            height: kUiHeight,
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
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

// —— 录音态：麦克风 + 计时 + 流式 partial + 底部指示条 ——
class _RecordingBody extends StatelessWidget {
  final SessionData data;
  const _RecordingBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.mic, color: cs.onErrorContainer, size: 22),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_fmtMs(data.elapsedMs),
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontFeatures: [
                        ui.FontFeature.tabularFigures(),
                      ])),
                  Text('正在听…', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                data.partial.isEmpty ? ' ' : data.partial,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Text('识别结果', style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
    final items = data.candidates.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text('LLM 优化',
                  style: Theme.of(context).textTheme.labelMedium),
              const Spacer(),
              Text('数字选择 · Enter=1 · Esc=取消',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        for (var i = 0; i < items.length; i++)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: i == 0 ? cs.primary : cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Text('${i + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    color: i == 0 ? cs.onPrimary : cs.onSurfaceVariant,
                  )),
            ),
            title: Text(
              items[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: i == 0
                  ? Theme.of(context).textTheme.titleSmall
                  : Theme.of(context).textTheme.bodyMedium,
            ),
            subtitle: i == 0
                ? Text('润色版',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.primary))
                : null,
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
          color: Theme.of(context).colorScheme.outline, size: 32),
    );
  }
}
