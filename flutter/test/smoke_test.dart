// 占位冒烟测试（面板构建不崩）
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ui/main.dart';

void main() {
  testWidgets('idle panel builds', (tester) async {
    await tester.pumpWidget(const VoiceUiApp());
    expect(find.byType(VoicePanel), findsOneWidget);
  });
}
