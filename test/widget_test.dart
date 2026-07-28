import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_horus/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  void mockLocalStorage() {
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
  }

  testWidgets('shows recorder home screen', (WidgetTester tester) async {
    mockLocalStorage();

    await tester.pumpWidget(const HorusRecorderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Record Horus'), findsOneWidget);
    expect(find.text('Bắt đầu ghi'), findsOneWidget);
    expect(find.text('Nhãn'), findsOneWidget);
  });

  testWidgets('asks for label before recording', (WidgetTester tester) async {
    mockLocalStorage();

    await tester.pumpWidget(const HorusRecorderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Bắt đầu ghi'));
    await tester.pumpAndSettle();

    expect(find.text('Chọn nhãn ghi âm'), findsOneWidget);
    expect(find.text('Chung'), findsWidgets);
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('can create label from recording label dialog', (
    WidgetTester tester,
  ) async {
    mockLocalStorage();

    await tester.pumpWidget(const HorusRecorderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Bắt đầu ghi'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Kho A');
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();

    expect(find.text('Kho A'), findsOneWidget);
  });
}
