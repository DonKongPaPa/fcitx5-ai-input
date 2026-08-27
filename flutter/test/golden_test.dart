// golden 基线：固定表面尺寸下渲染关键状态，与 goldens/ 下的参考图逐
// 像素比对。基线在 ui-test 容器（SDK pin 3.47.0）内生成/校验——宿主
// SDK 版本不同会有亚像素差异，属预期。
// 更新基线：容器内 `flutter test --update-goldens test/golden_test.dart`
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ui/main.dart';
import 'package:voice_ui/mock_host.dart';

import 'replay_test.dart' show loadEnvelopes, loadTestFonts;

void main() {
  const size = Size(440, 260);

  testWidgets('golden：录音态卡片', (tester) async {
    await loadTestFonts();
    await tester.binding.setSurfaceSize(size);
    final host = MockHost();
    await tester.pumpWidget(VoiceUiApp(transport: host));
    unawaited(host.play(MockHost.fromEnvelopes(
        loadEnvelopes('../lab/spec/events/voice-full.jsonl'))));
    // 推进到第一个 partial 已显示（约 1s）
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
        find.byType(VoicePanel), matchesGoldenFile('goldens/recording.png'));
    // 推到脚本尾（idle）：录音 ticker 是周期定时器，不在测试结束前取消
    // 会以 "Timer still pending" 报失败
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('golden：候选态卡片', (tester) async {
    await loadTestFonts();
    await tester.binding.setSurfaceSize(size);
    final host = MockHost();
    await tester.pumpWidget(VoiceUiApp(transport: host));
    unawaited(host.play(MockHost.fromEnvelopes(
        loadEnvelopes('../lab/spec/events/voice-full.jsonl'))));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(VoicePanel), matchesGoldenFile('goldens/candidates.png'));
  });
}
