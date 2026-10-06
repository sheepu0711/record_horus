import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_horus/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const control = MethodChannel('com.example.record_horus/recording_control');
  const record = MethodChannel('com.llfbandit.record/messages');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const codec = StandardMethodCodec();
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late List<MethodCall> controls;
  late List<String> recorderCalls;
  String? currentPath;
  String? eventsChannel;
  bool failPause = false;
  bool failStop = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('horus_ios_test_');
    controls = [];
    recorderCalls = [];
    currentPath = null;
    eventsChannel = null;
    failPause = false;
    failStop = false;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(secure, (_) async => null);
    messenger.setMockMethodCallHandler(control, (call) async {
      controls.add(call);
      return call.method == 'update' ? true : null;
    });
    messenger.setMockMethodCallHandler(record, (call) async {
      recorderCalls.add(call.method);
      switch (call.method) {
        case 'create':
          eventsChannel =
              'com.llfbandit.record/events/${(call.arguments as Map)['recorderId']}';
          messenger.setMockMethodCallHandler(
            MethodChannel(eventsChannel!),
            (_) async => null,
          );
          return null;
        case 'hasPermission':
        case 'isEncoderSupported':
        case 'isRecording':
          return true;
        case 'getAmplitude':
          return {'current': -40.0, 'max': -20.0};
        case 'start':
          currentPath = (call.arguments as Map)['path'] as String;
          await File(currentPath!).writeAsBytes([1, 2, 3]);
          return null;
        case 'stop':
          if (failStop) {
            throw PlatformException(code: 'stop_failed');
          }
          return currentPath;
        case 'pause':
          if (failPause) {
            throw PlatformException(code: 'pause_failed');
          }
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    for (final channel in [
      control,
      record,
      paths,
      secure,
      if (eventsChannel != null) MethodChannel(eventsChannel!),
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await directory.delete(recursive: true);
  });

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const HorusRecorderApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bắt đầu ghi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    // Advance widget microtasks as well as real filesystem operations.
    for (
      var i = 0;
      i < 100 && !controls.any((call) => call.method == 'update');
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    expect(
      controls.where((call) => call.method == 'update'),
      isNotEmpty,
      reason:
          'Recorder: $recorderCalls; UI: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(" | ")}',
    );
  }

  Future<bool> action(WidgetTester tester, String action, {String? id}) async {
    final result = await tester.runAsync(() async {
      final reply = Completer<bool>();
      messenger.handlePlatformMessage(
        control.name,
        codec.encodeMethodCall(
          MethodCall('performAction', {
            'action': action,
            'recordingId': id ?? currentPath,
          }),
        ),
        (data) {
          reply.complete(codec.decodeEnvelope(data!) as bool);
        },
      );
      return reply.future;
    });
    await tester.pump();
    return result!;
  }

  testWidgets(
    'Live Activity pauses, resumes and saves a recording locally',
    (tester) async {
      await start(tester);
      expect(
        controls.any((call) => call.method == 'requestNotificationPermission'),
        isFalse,
      );
      expect(await action(tester, 'pause'), isTrue);
      expect((controls.last.arguments as Map)['paused'], isTrue);
      expect(await action(tester, 'resume'), isTrue);
      expect((controls.last.arguments as Map)['paused'], isFalse);
      expect(await action(tester, 'stop'), isTrue);
      final prefs = await SharedPreferences.getInstance();
      final recordings =
          jsonDecode(prefs.getString('record_horus.recordings.v1')!) as List;
      expect(recordings, hasLength(1));
      expect(
        await tester.runAsync(
          () => File(recordings.single['filePath'] as String).exists(),
        ),
        isTrue,
      );
      expect(await tester.runAsync(() => File(currentPath!).exists()), isFalse);
      expect(controls.last.method, 'stop');
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'stale activity cannot cancel the current recording; cancel discards only its file',
    (tester) async {
      await start(tester);
      expect(await action(tester, 'cancel', id: 'old-recording'), isFalse);
      expect(recorderCalls.where((method) => method == 'stop'), isEmpty);
      expect(await tester.runAsync(() => File(currentPath!).exists()), isTrue);
      expect(await action(tester, 'cancel'), isTrue);
      expect(await tester.runAsync(() => File(currentPath!).exists()), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('record_horus.recordings.v1'), isNull);
      expect(controls.last.method, 'stop');
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'failed pause and stop keep recording controls available for retry',
    (tester) async {
      await start(tester);
      failPause = true;
      expect(await action(tester, 'pause'), isFalse);
      expect(controls.where((call) => call.method == 'update'), hasLength(1));
      failStop = true;
      expect(await action(tester, 'stop'), isFalse);
      expect(controls.where((call) => call.method == 'stop'), isEmpty);
      expect(await tester.runAsync(() => File(currentPath!).exists()), isTrue);
      failStop = false;
      expect(await action(tester, 'stop'), isTrue);
      expect(controls.last.method, 'stop');
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
