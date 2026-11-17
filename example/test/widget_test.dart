import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_dual_bridge_example/main.dart';

void main() {
  testWidgets('shows dual bridge home', (WidgetTester tester) async {
    await tester.pumpWidget(const NearbyDualBridgeExampleApp());
    expect(find.text('Nearby Dual Bridge'), findsOneWidget);
    expect(find.text('Start Host'), findsOneWidget);
    expect(find.text('Scan Hosts'), findsOneWidget);
  });
}
