import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_horus/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows recorder home screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    const secureStorageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });

    await tester.pumpWidget(const HorusRecorderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Record Horus'), findsOneWidget);
    expect(find.text('Bắt đầu ghi'), findsOneWidget);
    expect(find.text('Nhãn'), findsOneWidget);
  });
}
