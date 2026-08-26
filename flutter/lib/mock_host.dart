// UI 传输层：进程内 MethodChannel（嵌入态）与回放 MockHost（试验田/测试）。
//
// 协议 v1 见 lab/spec/protocol.md：envelope {channel,dir,method,args}；
// ui 侧只消费 channel=ui 且 dir=out 的事件。进程内传输里 method 直接用
// MethodCall.method 承载（'update' 为旧 wire，过渡期由 UI 侧归一化）。
// 回放文件（.jsonl）：每行一个 envelope 或控制行（_delay_ms/_comment）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef UiMessageSink = void Function(
    String method, Map<String, dynamic> args);

abstract class UiTransport {
  /// 宿主侧（channel 对端或回放器）→ UI 的消息入口
  void attach(UiMessageSink sink);

  /// UI → 宿主侧命令（ready/resize/select/hover/...）
  Future<void> send(String method, Map<String, dynamic> args);
}

/// 嵌入态：raw embedder 的 platform channel（现状通道）
class ChannelTransport implements UiTransport {
  static const _ch = MethodChannel('fcitx5/flutterui', JSONMethodCodec());
  const ChannelTransport();

  @override
  void attach(UiMessageSink sink) {
    _ch.setMethodCallHandler((call) async {
      final args =
          (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      sink(call.method, args);
      return null;
    });
  }

  @override
  Future<void> send(String method, Map<String, dynamic> args) async {
    // 无对端（flutter run 调试态）时静默：channel 调用会抛 MissingPluginException
    await _ch.invokeMethod(method, args).catchError((_) => null);
  }
}

/// 回放宿主：把 .jsonl 脚本按 _delay_ms 节奏喂给 UI，并记录 UI 发出的
/// 全部命令（测试断言/控制台观测用）
class MockHost implements UiTransport {
  UiMessageSink? _sink;
  final List<Map<String, dynamic>> commands = [];

  @override
  void attach(UiMessageSink sink) => _sink = sink;

  @override
  Future<void> send(String method, Map<String, dynamic> args) async {
    commands.add({'method': method, ...args});
    // ignore: avoid_print
    print('[mock-ui] -> $method $args');
  }

  /// 解析回放脚本：返回 (delayMs, method, args) 序列（只取 ui/out 行；
  /// 脚本解码由调用方 dart:convert 完成，这里保持零依赖）
  static List<MapEntry<int, MapEntry<String, Map<String, dynamic>>>>
      fromEnvelopes(List<Map<String, dynamic>> envelopes) {
    final events = <MapEntry<int, MapEntry<String, Map<String, dynamic>>>>[];
    for (final e in envelopes) {
      if (e.containsKey('_comment')) continue;
      if (e['channel'] != 'ui' || e['dir'] != 'out') continue;
      final delay = (e['_delay_ms'] as num?)?.toInt() ?? 0;
      final method = e['method'] as String;
      final args = (e['args'] as Map?)?.cast<String, dynamic>() ?? const {};
      events.add(MapEntry(delay, MapEntry(method, args)));
    }
    return events;
  }

  /// 播放已解码的事件序列（tests/widget 内用 fake clock 驱动 delay）
  Future<void> play(List<MapEntry<int, MapEntry<String, Map<String, dynamic>>>>
      events) async {
    for (final e in events) {
      if (e.key > 0) await Future<void>.delayed(Duration(milliseconds: e.key));
      _sink?.call(e.value.key, e.value.value);
    }
  }
}
