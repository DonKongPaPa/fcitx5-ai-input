// 回放驱动测试：lab/spec/events/*.jsonl（协议 v1）喂给 MockHost → UI，
// 断言状态机/文本/命令流。这就是 ui-test 容器的核心用例族。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ui/main.dart';
import 'package:voice_ui/mock_host.dart';

List<Map<String, dynamic>> loadEnvelopes(String rel) => File(rel)
    .readAsLinesSync()
    .where((l) => l.trim().isNotEmpty)
    .map((l) => Map<String, dynamic>.from(jsonDecode(l) as Map))
    .toList();

Future<void> loadTestFonts() async {
  final loader = FontLoader('NotoSansSC')
    ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
  await loader.load();
}

void main() {
  testWidgets('voice-full：录音流式→候选→选择命令→idle（v1 事件全状态）',
      (tester) async {
    await loadTestFonts();
    await tester.binding.setSurfaceSize(const Size(480, 320));
    final host = MockHost();
    await tester.pumpWidget(VoiceUiApp(transport: host));
    expect(find.byType(VoicePanel), findsOneWidget);
    // ready 是首条命令
    expect(host.commands.first['method'], 'ready');

    final events = MockHost.fromEnvelopes(
        loadEnvelopes('../lab/spec/events/voice-full.jsonl'));
    expect(events, isNotEmpty);
    unawaited(host.play(events));
    // candidates 事件在累计 ~3.6s 到达；idle 已放宽到 +1500ms。定量推进：
    // 3.8s 候选已到、+800ms 让 AnimatedSize（慢速挡 ~660ms）长完——
    // 不能用 pumpAndSettle（会把时钟推过 idle）
    await tester.pump(const Duration(milliseconds: 3800));
    await tester.pump(const Duration(milliseconds: 800));

    // 候选态：主文本与两行候选都在
    expect(find.text('你好，这是语音输入。'), findsAtLeastNWidgets(1));
    expect(find.text('你好这是语音输入'), findsAtLeastNWidgets(1));
    // 状态切换产生过 resize 命令（内在尺寸上报链路活着）
    expect(host.commands.any((c) => c['method'] == 'resize'), isTrue);

    // 点击首行候选 → select 命令（v1 名称）
    await tester.tap(find.text('你好，这是语音输入。').first);
    await tester.pump();
    expect(host.commands.any((c) => c['method'] == 'select'), isTrue);

    // 收尾 idle 到达后卡片收起
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('你好，这是语音输入。'), findsNothing);
  });

  testWidgets('voice-result-auto：result 态超时回到 idle', (tester) async {
    await loadTestFonts();
    final host = MockHost();
    await tester.pumpWidget(VoiceUiApp(transport: host));
    final events = MockHost.fromEnvelopes(
        loadEnvelopes('../lab/spec/events/voice-result-auto.jsonl'));
    unawaited(host.play(events));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    // idle 后结果文本不残留（idle 体无会话内容）
    expect(find.text('测试。'), findsNothing);
  });

  testWidgets('theme-change：录音中热改字号不崩（尺寸重报深度覆盖在 e2e c12'
      '——FontLoader 真实 I/O 在 fake clock 下不可稳定驱动）', (tester) async {
    await loadTestFonts();
    await tester.binding.setSurfaceSize(const Size(480, 320));
    final host = MockHost();
    await tester.pumpWidget(VoiceUiApp(transport: host));
    final events = MockHost.fromEnvelopes(
        loadEnvelopes('../lab/spec/events/theme-change.jsonl'));
    unawaited(host.play(events));
    // recording2（改档后）在 ~1.0s、idle 在 ~1.4s——停在中间窗口
    await tester.pump(const Duration(milliseconds: 1200));
    // _applyFont 的字体文件读取是真实异步 I/O——FakeAsync 的 pump 推不
    // 动它，用 runAsync 放行一段真实事件循环再回来冲帧（断言必须赶在
    // pumpAndSettle 之前：settle 会把时钟推过脚本尾的 idle）
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    expect(host.commands.where((c) => c['method'] == 'resize').length,
        greaterThanOrEqualTo(1));
    expect(find.text('字体切换后'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  test('fromEnvelopes 过滤：只取 ui/out，跳过注释与其它通道', () {
    final ev = MockHost.fromEnvelopes([
      {'_comment': 'x'},
      {'channel': 'ui', 'dir': 'out', 'method': 'voice/idle', 'args': {}},
      {'channel': 'ui', 'dir': 'in', 'method': 'select', 'args': {'index': 0}},
      {'channel': 'asr', 'dir': 'in', 'method': 'asr/partial', 'args': {}},
      {
        'channel': 'ui',
        'dir': 'out',
        'method': 'voice/recording',
        'args': {'partial': 'a'},
        '_delay_ms': 120
      },
    ]);
    expect(ev.length, 2);
    expect(ev[0].key, 0);
    expect(ev[1].key, 120);
    expect(ev[1].value.key, 'voice/recording');
  });
}
