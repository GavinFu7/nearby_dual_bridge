import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nearby_dual_bridge/nearby_dual_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DualBridgeManager constructs', (WidgetTester tester) async {
    final bridge = DualBridgeManager();
    expect(bridge.role, BridgeRole.idle);
    expect(bridge.connectionState, BridgeConnectionState.disconnected);
    await bridge.dispose();
  });
}
