import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import 'app_models.dart';
import 'horus_drive_service.dart';
import 'local_store.dart';

const _stableFontFamily = 'Roboto';
const _stableFontFallback = ['Noto Sans', 'sans-serif'];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HorusRecorderApp());
}

class HorusRecorderApp extends StatelessWidget {
  const HorusRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF006C67), surface: Colors.white);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Record Horus',
      builder: (context, child) {
        return DefaultTextHeightBehavior(
          textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: _stableFontFamily,
        fontFamilyFallback: _stableFontFallback,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF6F8FA),
        appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0, scrolledUnderElevation: 0),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        ),
      ),
      home: const RecorderHomePage(),
    );
  }
}

class RecorderHomePage extends StatefulWidget {
  const RecorderHomePage({super.key});

  @override
  State<RecorderHomePage> createState() => _RecorderHomePageState();
}

class _RecorderHomePageState extends State<RecorderHomePage> {
  final _localStore = LocalStore();
  final _settingsStore = HorusSettingsStore();
  HorusDriveService? _driveService;
  AudioPlayer? _audioPlayer;
  late final AudioRecorder _recorder;

  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<PlayerState>? _playbackStateSubscription;
  StreamSubscription<Duration>? _playbackPositionSubscription;
  StreamSubscription<Duration?>? _playbackDurationSubscription;
  Timer? _elapsedTimer;
  final _recordingClock = Stopwatch();

  List<LabelItem> _labels = const [];
  List<RecordingItem> _recordings = const [];
  HorusSettings _settings = HorusSettings.defaults();

  String? _selectedLabelId;
  DateTime? _recordingStartedAt;
  String? _tempRecordingPath;
  Duration _elapsed = Duration.zero;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;
  List<double> _waveSamples = List<double>.filled(56, 0.12);
  double _noiseFloorDb = -62;
  double _peakDb = -24;
  int _waveTick = 0;
  bool _loading = true;
  bool _busy = false;
  bool _playbackBusy = false;
  bool _isRecording = false;
  bool _isPaused = false;
  String? _loadedPlaybackId;
  String? _playingRecordingId;
  final Set<String> _uploadingIds = {};
  final Set<String> _linkingIds = {};
  final Set<String> _sharingIds = {};

  // Notification Android / Live Activity iOS.
  static const _recordingControlChannel = MethodChannel('com.example.record_horus/recording_control');
  static const _recordingActionChannel = EventChannel('com.example.record_horus/recording_actions');
  StreamSubscription<dynamic>? _notificationActionSubscription;

  HorusDriveService get _drive => _driveService ??= HorusDriveService();

  AudioPlayer get _player => _audioPlayer ??= _createPlayer();

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    _recordStateSubscription = _recorder.onStateChanged().listen((state) {
      if (!mounted) {
        return;
      }
      if (state == RecordState.stop && !_busy && _tempRecordingPath != null &&
          defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(_stopRecording());
        return;
      }
      setState(() {
        _isRecording = state != RecordState.stop;
        _isPaused = state == RecordState.pause;
      });
      if (state == RecordState.record) {
        _recordingClock.start();
      } else {
        _recordingClock.stop();
      }
      if ((defaultTargetPlatform == TargetPlatform.iOS) && !_busy && _tempRecordingPath != null && state != RecordState.stop) {
        unawaited(_showRecordingNotification(paused: _isPaused, label: _selectedLabel?.name ?? 'Chung'));
      }
    });
    if (Platform.isAndroid) {
      _notificationActionSubscription = _recordingActionChannel.receiveBroadcastStream().listen((event) {
        if (event is String) {
          unawaited(_handleNotificationAction(event));
        }
      });
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      _recordingControlChannel.setMethodCallHandler((call) async {
        if (call.method != 'performAction') {
          throw MissingPluginException();
        }
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        if (arguments['recordingId'] != _tempRecordingPath || _busy) {
          return false;
        }
        await _handleNotificationAction(arguments['action'] as String);
        return switch (arguments['action']) {
          'pause' => _isRecording && _isPaused,
          'resume' => _isRecording && !_isPaused,
          'stop' || 'cancel' => !_isRecording,
          _ => false,
        };
      });
      unawaited(_recordingControlChannel.invokeMethod<void>('ready'));
    }
    unawaited(_loadAppState());
  }

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _recordingControlChannel.setMethodCallHandler(null);
    }
    _elapsedTimer?.cancel();
    unawaited(_notificationActionSubscription?.cancel());
    unawaited(_recordStateSubscription?.cancel());
    unawaited(_amplitudeSubscription?.cancel());
    unawaited(_playbackStateSubscription?.cancel());
    unawaited(_playbackPositionSubscription?.cancel());
    unawaited(_playbackDurationSubscription?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_audioPlayer?.dispose());
    _driveService?.close();
    super.dispose();
  }

  LabelItem? get _selectedLabel {
    for (final label in _labels) {
      if (label.id == _selectedLabelId) {
        return label;
      }
    }
    return _labels.isEmpty ? null : _labels.first;
  }

  AudioPlayer _createPlayer() {
    final player = AudioPlayer();
    _playbackStateSubscription = player.playerStateStream.listen((state) {
      if (!mounted) {
        return;
      }
      if (state.processingState == ProcessingState.completed) {
        unawaited(player.seek(Duration.zero));
        unawaited(player.pause());
        setState(() {
          _playingRecordingId = null;
          _playbackPosition = Duration.zero;
        });
        return;
      }
      setState(() {
        if (!state.playing) {
          _playingRecordingId = null;
        }
      });
    });
    _playbackPositionSubscription = player.positionStream.listen((position) {
      if (!mounted || _loadedPlaybackId == null) {
        return;
      }
      setState(() => _playbackPosition = position);
    });
    _playbackDurationSubscription = player.durationStream.listen((duration) {
      if (!mounted || duration == null) {
        return;
      }
      setState(() => _playbackDuration = duration);
    });
    return player;
  }

  Future<void> _loadAppState() async {
    final labels = await _localStore.loadLabels();
    var recordings = await _localStore.loadRecordings();
    if ((defaultTargetPlatform == TargetPlatform.iOS) && recordings.isNotEmpty) {
      // iOS may change the sandbox's absolute path after an app update/restore.
      final directory = await _recordingsDirectory();
      recordings = recordings.map((item) => item.copyWith(
        filePath: '${directory.path}${Platform.pathSeparator}${item.fileName}',
      )).toList();
    }
    final settings = await _settingsStore.load();

    if (!mounted) {
      return;
    }

    setState(() {
      _labels = labels;
      _recordings = recordings;
      _settings = settings;
      _selectedLabelId = labels.first.id;
      _loading = false;
    });
  }

  // ---------------------------------------------------------------------
  // Notification ghi âm (Android)
  // ---------------------------------------------------------------------

  /// Đảm bảo app được phép hiện notification.
  ///
  /// Android 13+ cần quyền runtime `POST_NOTIFICATIONS`; trên một số máy
  /// (đặc biệt Xiaomi/MIUI) người dùng còn phải bật thêm trong cài đặt
  /// thông báo của app. Trả về true nếu notification có thể hiển thị.
  Future<bool> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return false;
    }
    Map<String, dynamic>? result;
    try {
      result = (await _recordingControlChannel.invokeMethod<Map<Object?, Object?>>(
        'requestNotificationPermission',
      ))?.cast<String, dynamic>();
    } catch (_) {
      // Không phải Android (web/iOS/...): coi như không cần notification.
      return false;
    }
    if (result == null) {
      return false;
    }

    final enabled = result['enabled'] == true;
    if (enabled) {
      return true;
    }

    // Chưa bật: mở màn cài đặt thông báo để người dùng tự bật.
    if (mounted) {
      await _showNotificationBlockedDialog();
    }
    try {
      await _recordingControlChannel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {
      // Bỏ qua nếu không mở được cài đặt.
    }
    return false;
  }

  Future<void> _showNotificationBlockedDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Cần bật thông báo'),
          content: const Text(
            'Để điều khiển ghi âm (Tạm dừng / Dừng) từ thanh thông báo, '
            'hãy bật "Cho phép thông báo" cho app.\n\n'
            'Trên Xiaomi/MIUI: Cài đặt > Ứng dụng > Quản lý ứng dụng > '
            'Record Horus > Thông báo > Bật "Hiển thị thông báo".',
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Đã hiểu'))],
        );
      },
    );
  }

  Future<void> _showRecordingNotification({required bool paused, required String label}) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final enabled = await _recordingControlChannel.invokeMethod<bool>('update', <String, dynamic>{
          'paused': paused,
          'label': label,
          'recordingId': _tempRecordingPath,
        });
        if (enabled == false && _elapsed == Duration.zero) {
          _showSnack('Live Activity chưa khả dụng. Bạn vẫn có thể điều khiển ghi âm trong app.');
        }
        return;
      }
      if (paused) {
        await _recordingControlChannel.invokeMethod<void>('setPaused', <String, dynamic>{
          'paused': true,
          'label': label,
        });
      } else {
        await _recordingControlChannel.invokeMethod<void>('start', <String, dynamic>{'label': label});
      }
    } catch (_) {
      // Không phải Android: bỏ qua.
    }
  }

  Future<void> _dismissRecordingNotification() async {
    try {
      await _recordingControlChannel.invokeMethod<void>('stop');
    } catch (_) {
      // Không phải Android: bỏ qua.
    }
  }

  Future<void> _handleNotificationAction(String action) async {
    switch (action) {
      case 'pause':
        if (_isRecording && !_isPaused) {
          await _togglePause();
        }
        break;
      case 'resume':
        if (_isRecording && _isPaused) {
          await _togglePause();
        }
        break;
      case 'stop':
        if (_isRecording) {
          await _stopRecording();
        }
        break;
      case 'cancel':
        await _cancelRecording();
        break;
    }
  }

  Future<void> _startRecording() async {
    if (_busy || _isRecording) {
      return;
    }

    final label = await _pickRecordingLabel();
    if (label == null) {
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() => _selectedLabelId = label.id);
    setState(() => _busy = true);

    try {
      await _stopPlayback(resetLoadedRecording: true);

      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _showSnack('Chưa có quyền dùng microphone');
        return;
      }

      const encoder = AudioEncoder.aacLc;
      final supported = await _recorder.isEncoderSupported(encoder);
      if (!supported) {
        throw Exception('Thiết bị không hỗ trợ ghi âm AAC');
      }

      final startedAt = DateTime.now();
      final directory = await _recordingsDirectory();
      final tempPath =
          '${directory.path}${Platform.pathSeparator}.record_horus_${startedAt.microsecondsSinceEpoch}.m4a';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
          noiseSuppress: true,
        ),
        path: tempPath,
      );

      // Đảm bảo app được phép hiện notification (Android 13+ cần quyền
      // POST_NOTIFICATIONS; trên Xiaomi/MIUI có thể phải bật thêm trong
      // cài đặt thông báo của app) rồi mới hiện notification ghi âm.
      // Notification này giữ process foreground để mic không bị câm khi
      // tắt màn hình / chuyển app (lỗi chỉ nghe được ~1 phút đầu).
      final canShowNotification = await _ensureNotificationPermission();
      if (canShowNotification) {
        unawaited(_showRecordingNotification(paused: false, label: label.name));
      }

      _elapsedTimer?.cancel();
      if (!mounted) {
        return;
      }

      setState(() {
        _recordingStartedAt = startedAt;
        _tempRecordingPath = tempPath;
        _elapsed = Duration.zero;
        _waveSamples = List<double>.filled(56, 0.12);
        _noiseFloorDb = -62;
        _peakDb = -24;
        _waveTick = 0;
        _isRecording = true;
        _isPaused = false;
        _busy = false;
      });
      _startAmplitudeMonitoring();
      _recordingClock..reset()..start();
      _startElapsedTimer();
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _showRecordingNotification(paused: false, label: label.name);
      }
      unawaited(HapticFeedback.mediumImpact());
    } catch (error) {
      _showSnack(_friendlyError(error));
    } finally {
      if (mounted && _busy && !_isRecording) {
        setState(() => _busy = false);
      }
    }
  }

  Future<LabelItem?> _pickRecordingLabel() async {
    final picked = await showDialog<LabelItem>(
      context: context,
      builder: (context) {
        return _SelectRecordingLabelDialog(
          labels: _labels,
          initialLabelId: _selectedLabel?.id,
          newLabelId: () => _newId(),
        );
      },
    );
    if (picked == null) {
      return null;
    }

    final labelExists = _labels.any((label) => label.id == picked.id);
    if (!labelExists) {
      final next = [..._labels, picked];
      await _localStore.saveLabels(next);
      if (!mounted) {
        return picked;
      }
      setState(() => _labels = next);
    }

    return picked;
  }

  Future<void> _stopRecording() async {
    if (_busy || !_isRecording) {
      return;
    }

    final label = _selectedLabel;
    final startedAt = _recordingStartedAt ?? DateTime.now();
    var stopped = false;
    setState(() => _busy = true);

    try {
      final stoppedPath = await _recorder.stop();
      stopped = true;
      _recordingClock.stop();
      final endedAt = DateTime.now();
      _elapsedTimer?.cancel();
      _stopAmplitudeMonitoring();

      final sourcePath = stoppedPath ?? _tempRecordingPath;
      if (sourcePath == null) {
        throw Exception('Không lấy được file ghi âm');
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        throw Exception('Không tìm thấy file ghi âm');
      }

      final directory = await _recordingsDirectory();
      final fileName = _buildRecordingFileName(label?.name ?? 'Chung', startedAt, endedAt);
      final targetFile = await _uniqueFile(directory, fileName);
      final savedFile = await sourceFile.rename(targetFile.path);

      final recording = RecordingItem(
        id: _newId(endedAt),
        label: label?.name ?? 'Chung',
        startedAt: startedAt,
        endedAt: endedAt,
        filePath: savedFile.path,
        fileName: _fileNameFromPath(savedFile.path),
      );
      final nextRecordings = [recording, ..._recordings];
      await _localStore.saveRecordings(nextRecordings);

      if (!mounted) {
        return;
      }

      setState(() {
        _recordings = nextRecordings;
        _recordingStartedAt = null;
        _tempRecordingPath = null;
        _elapsed = Duration.zero;
        _waveSamples = List<double>.filled(56, 0.12);
        _noiseFloorDb = -62;
        _peakDb = -24;
        _waveTick = 0;
        _isRecording = false;
        _isPaused = false;
      });
      // Xoá notification ghi âm khi dừng.
      await _dismissRecordingNotification();
      unawaited(HapticFeedback.selectionClick());
      _showSnack('Đã lưu: ${recording.fileName}');
    } catch (error) {
      if (mounted && stopped) {
        _stopAmplitudeMonitoring();
        setState(() {
          _recordingStartedAt = null;
          _tempRecordingPath = null;
          _elapsed = Duration.zero;
          _waveSamples = List<double>.filled(56, 0.12);
          _noiseFloorDb = -62;
          _peakDb = -24;
          _waveTick = 0;
          _isRecording = false;
          _isPaused = false;
        });
      }
      _showSnack(_friendlyError(error));
    } finally {
      if (stopped) {
        await _dismissRecordingNotification();
      }
      if (mounted && _busy) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _togglePause() async {
    if (!_isRecording || _busy) {
      return;
    }

    final nextPaused = !_isPaused;
    setState(() => _busy = true);
    try {
      if (nextPaused) {
        await _recorder.pause();
        _recordingClock.stop();
      } else {
        await _recorder.resume();
        _recordingClock.start();
      }
      if (!mounted) {
        return;
      }
      setState(() => _isPaused = nextPaused);
      // Đồng bộ trạng thái lên notification (đổi nút Pause/Resume + tạm
      // ngừng đếm thời gian).
      await _showRecordingNotification(paused: nextPaused, label: _selectedLabel?.name ?? 'Chung');
    } catch (error) {
      _showSnack(_friendlyError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancelRecording() async {
    if (_busy || !_isRecording) {
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await _recorder.stop() ?? _tempRecordingPath;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      _recordingClock.stop();
      _elapsedTimer?.cancel();
      _stopAmplitudeMonitoring();
      if (!mounted) {
        return;
      }
      setState(() {
        _recordingStartedAt = null;
        _tempRecordingPath = null;
        _elapsed = Duration.zero;
        _isRecording = false;
        _isPaused = false;
        _waveSamples = List<double>.filled(56, 0.12);
      });
      await _dismissRecordingNotification();
      _showSnack('Đã hủy bản ghi đang ghi');
    } catch (error) {
      _showSnack(_friendlyError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _togglePlayback(RecordingItem recording) async {
    if (_playbackBusy) {
      return;
    }

    final player = _player;
    final isSameRecording = _loadedPlaybackId == recording.id;
    if (isSameRecording && _playingRecordingId == recording.id) {
      await player.pause();
      if (!mounted) {
        return;
      }
      setState(() => _playingRecordingId = null);
      return;
    }

    setState(() => _playbackBusy = true);

    try {
      final file = File(recording.filePath);
      if (!await file.exists()) {
        throw Exception('Không tìm thấy file ghi âm local');
      }

      if (!isSameRecording) {
        final duration = await player.setFilePath(recording.filePath);
        if (!mounted) {
          return;
        }
        setState(() {
          _loadedPlaybackId = recording.id;
          _playbackPosition = Duration.zero;
          _playbackDuration = duration ?? recording.duration;
        });
      }

      if (!mounted) {
        return;
      }
      setState(() => _playingRecordingId = recording.id);
      unawaited(
        player.play().catchError((Object error) {
          if (!mounted) {
            return;
          }
          setState(() => _playingRecordingId = null);
          _showSnack(_friendlyError(error));
        }),
      );
      unawaited(HapticFeedback.selectionClick());
    } catch (error) {
      _showSnack(_friendlyError(error));
    } finally {
      if (mounted) {
        setState(() => _playbackBusy = false);
      }
    }
  }

  Future<void> _seekPlayback(double milliseconds) async {
    final player = _audioPlayer;
    if (player == null || _loadedPlaybackId == null) {
      return;
    }
    await player.seek(Duration(milliseconds: milliseconds.round()));
  }

  Future<void> _stopPlayback({bool resetLoadedRecording = false}) async {
    final player = _audioPlayer;
    if (player == null) {
      return;
    }
    await player.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _playingRecordingId = null;
      _playbackPosition = Duration.zero;
      if (resetLoadedRecording) {
        _loadedPlaybackId = null;
        _playbackDuration = Duration.zero;
      }
    });
  }

  Future<void> _shareRecording(RecordingItem recording, BuildContext buttonContext) async {
    if (_sharingIds.contains(recording.id)) {
      return;
    }

    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharingIds.add(recording.id));
    try {
      if (!await File(recording.filePath).exists()) {
        _showSnack('Không tìm thấy file ghi âm trên máy');
        return;
      }
      if (!mounted) {
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(recording.filePath, mimeType: 'audio/mp4')],
          subject: recording.fileName,
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      _showSnack('Không thể chia sẻ bản ghi: ${_friendlyError(error)}');
    } finally {
      if (mounted) {
        setState(() => _sharingIds.remove(recording.id));
      }
    }
  }

  Future<void> _copyRecordingLink(RecordingItem recording) async {
    if (_linkingIds.contains(recording.id)) {
      return;
    }

    final existingLink = recording.shareLink ?? recording.remotePath;
    if (recording.shareLink != null && recording.shareLink!.isNotEmpty) {
      await _copyText(recording.shareLink!, 'Đã copy link âm thanh');
      return;
    }

    if (!_settings.hasUploadCredentials) {
      if (existingLink != null && existingLink.isNotEmpty) {
        await _copyText(existingLink, 'Đã copy link WebDAV');
        return;
      }
      _showSnack('Cần cấu hình HorusDrive để lấy link');
      return;
    }

    setState(() => _linkingIds.add(recording.id));
    try {
      final link = await _drive.getRecordingLink(settings: _settings, recording: recording);
      final updated = recording.copyWith(shareLink: link);
      await _replaceRecording(updated);
      await _copyText(link, 'Đã copy link âm thanh');
    } catch (error) {
      if (existingLink != null && existingLink.isNotEmpty) {
        await _copyText(existingLink, 'Đã copy link WebDAV');
      } else {
        _showSnack('Chưa lấy được link: ${_friendlyError(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _linkingIds.remove(recording.id));
      }
    }
  }

  Future<void> _copyText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack(message);
  }

  Future<void> _uploadRecording(RecordingItem recording, {bool showSuccess = false}) async {
    if (_uploadingIds.contains(recording.id)) {
      return;
    }

    if (!_settings.hasUploadCredentials) {
      final updated = recording.copyWith(
        uploadError: 'Chưa cấu hình HorusDrive',
        clearUploadedAt: true,
        clearRemotePath: true,
        clearShareLink: true,
      );
      await _replaceRecording(updated);
      if (showSuccess) {
        _showSnack('Bản ghi đã lưu local');
      }
      return;
    }

    if (mounted) {
      setState(() => _uploadingIds.add(recording.id));
    }

    try {
      final result = await _drive.uploadRecording(settings: _settings, recording: recording);
      final updated = recording.copyWith(
        uploadedAt: DateTime.now(),
        remotePath: result.remotePath,
        shareLink: result.shareLink ?? result.remotePath,
        clearUploadError: true,
      );
      await _replaceRecording(updated);
      if (showSuccess) {
        _showSnack('Đã tải lên HorusDrive');
      }
    } catch (error) {
      final updated = recording.copyWith(
        uploadError: _friendlyError(error),
        clearUploadedAt: true,
        clearRemotePath: true,
        clearShareLink: true,
      );
      await _replaceRecording(updated);
      _showSnack('Chưa tải lên được: ${_friendlyError(error)}');
    } finally {
      if (mounted) {
        setState(() => _uploadingIds.remove(recording.id));
      }
    }
  }

  Future<void> _replaceRecording(RecordingItem updated) async {
    final next = _recordings.map((recording) => recording.id == updated.id ? updated : recording).toList();
    await _localStore.saveRecordings(next);
    if (!mounted) {
      return;
    }
    setState(() => _recordings = next);
  }

  Future<void> _deleteRecording(RecordingItem recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xoá bản ghi?'),
          content: Text(recording.fileName),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Huỷ')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Xoá'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    if (_loadedPlaybackId == recording.id) {
      await _stopPlayback(resetLoadedRecording: true);
    }

    final file = File(recording.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    final next = _recordings.where((item) => item.id != recording.id).toList(growable: false);
    await _localStore.saveRecordings(next);
    if (!mounted) {
      return;
    }
    setState(() => _recordings = next);
    _showSnack('Đã xoá bản ghi local');
  }

  Future<void> _openLabelEditor({LabelItem? label}) async {
    final existingNames = _labels
        .where((item) => item.id != label?.id)
        .map((item) => item.name.trim().toLowerCase())
        .toSet();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return _LabelDialog(
          title: label == null ? 'Thêm nhãn' : 'Sửa nhãn',
          initialName: label?.name ?? '',
          existingNames: existingNames,
        );
      },
    );

    final name = result?.trim();
    if (name == null || name.isEmpty) {
      return;
    }

    final next = label == null
        ? [..._labels, LabelItem(id: _newId(), name: name)]
        : _labels.map((item) => item.id == label.id ? item.copyWith(name: name) : item).toList();

    await _localStore.saveLabels(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _labels = next;
      _selectedLabelId = label?.id ?? next.last.id;
    });
  }

  Future<void> _deleteSelectedLabel() async {
    final label = _selectedLabel;
    if (label == null) {
      return;
    }
    if (_labels.length == 1) {
      _showSnack('Cần giữ ít nhất một nhãn');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xoá nhãn?'),
          content: Text(label.name),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Huỷ')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Xoá'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    final next = _labels.where((item) => item.id != label.id).toList(growable: false);
    await _localStore.saveLabels(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _labels = next;
      _selectedLabelId = next.first.id;
    });
  }

  Future<void> _openSettings() async {
    final result = await showDialog<HorusSettings>(
      context: context,
      builder: (context) => _SettingsDialog(settings: _settings, onTest: _testSettings),
    );

    if (result == null) {
      return;
    }

    await _settingsStore.save(result);
    if (!mounted) {
      return;
    }
    setState(() => _settings = result);
    _showSnack('Đã lưu cấu hình HorusDrive');
  }

  Future<String?> _testSettings(HorusSettings settings) async {
    try {
      await _drive.checkConnection(settings);
      return null;
    } catch (error) {
      return _friendlyError(error);
    }
  }

  Future<Directory> _recordingsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final directory = Directory('${base.path}${Platform.pathSeparator}recordings');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> _uniqueFile(Directory directory, String fileName) async {
    final dotIndex = fileName.lastIndexOf('.');
    final baseName = dotIndex == -1 ? fileName : fileName.substring(0, dotIndex);
    final extension = dotIndex == -1 ? '' : fileName.substring(dotIndex);

    var candidate = File('${directory.path}${Platform.pathSeparator}$fileName');
    var index = 2;
    while (await candidate.exists()) {
      candidate = File('${directory.path}${Platform.pathSeparator}$baseName-$index$extension');
      index += 1;
    }
    return candidate;
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isRecording || _isPaused) {
        return;
      }
      setState(() => _elapsed = _recordingClock.elapsed);
    });
  }

  void _pushWaveSample(double level) {
    setState(() {
      _waveSamples = [..._waveSamples.skip(1), level];
    });
  }

  void _startAmplitudeMonitoring() {
    unawaited(_amplitudeSubscription?.cancel());
    _amplitudeSubscription = _recorder.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((amplitude) {
      if (!mounted || !_isRecording || _isPaused) {
        return;
      }
      _pushWaveSample(_levelFromAmplitude(amplitude));
    });
  }

  void _stopAmplitudeMonitoring() {
    unawaited(_amplitudeSubscription?.cancel());
    _amplitudeSubscription = null;
  }

  double _levelFromAmplitude(Amplitude amplitude) {
    final db = amplitude.current;
    _waveTick += 1;

    if (db.isNaN || db.isInfinite || db <= -95) {
      return _animatedWaveFloor();
    }

    if (db < _noiseFloorDb) {
      _noiseFloorDb = _noiseFloorDb * 0.82 + db * 0.18;
    } else {
      _noiseFloorDb = _noiseFloorDb * 0.995 + db * 0.005;
    }

    if (db > _peakDb) {
      _peakDb = _peakDb * 0.68 + db * 0.32;
    } else {
      _peakDb = _peakDb * 0.96 + db * 0.04;
    }

    if (_peakDb - _noiseFloorDb < 16) {
      _peakDb = _noiseFloorDb + 16;
    }

    final normalized = ((db - _noiseFloorDb) / (_peakDb - _noiseFloorDb)).clamp(0.0, 1.0);
    final boosted = math.pow(normalized, 0.46).toDouble();
    final pulse = math.sin(_waveTick * 0.72) * 0.035;
    return (0.12 + boosted * 0.88 + pulse).clamp(0.10, 1.0);
  }

  double _animatedWaveFloor() {
    final pulse = math.sin(_waveTick * 0.65) * 0.035;
    return (0.13 + pulse).clamp(0.09, 0.2);
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _buildRecordingFileName(String label, DateTime startedAt, DateTime endedAt) {
    return '${_sanitizeLabel(label)}_${_formatForFile(startedAt)}_${_formatForFile(endedAt)}.m4a';
  }

  String _sanitizeLabel(String label) {
    final cleaned = label
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp('-+'), '-');
    return cleaned.isEmpty ? 'nhan' : cleaned;
  }

  String _friendlyError(Object error) {
    if (error is HorusDriveException) {
      return error.message;
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  String _newId([DateTime? value]) {
    return (value ?? DateTime.now()).microsecondsSinceEpoch.toString();
  }

  String _fileNameFromPath(String path) {
    return path.split(RegExp(r'[\\/]')).last;
  }

  String _formatForFile(DateTime value) {
    final local = value.toLocal();
    return '${local.year}${_two(local.month)}${_two(local.day)}_${_two(local.hour)}${_two(local.minute)}${_two(local.second)}';
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    return '${_two(local.day)}/${_two(local.month)}/${local.year} ${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${_two(minutes)}:${_two(seconds)}';
    }
    return '${_two(minutes)}:${_two(seconds)}';
  }

  String _two(int value) {
    return value.toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Record Horus'),
        actions: [
          IconButton(
            tooltip: 'Cài đặt HorusDrive',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        _buildDriveBanner(context),
                        const SizedBox(height: 16),
                        _buildRecorderCard(context),
                        const SizedBox(height: 16),
                        _buildLabelsCard(context),
                        const SizedBox(height: 24),
                        _buildRecordingsSection(context),
                      ]),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildDriveBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = _settings.hasUploadCredentials;
    final host = Uri.tryParse(_settings.serverUrl)?.host;
    final account = _settings.authMode == HorusAuthMode.bearer && _settings.username.trim().isEmpty
        ? 'Bearer token'
        : '${_settings.username}@${host ?? _settings.serverUrl}';
    final background = ready ? const Color(0xFFEAF6EF) : const Color(0xFFFFF6E7);
    final foreground = ready ? const Color(0xFF0D6B3F) : const Color(0xFF8A4F00);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(ready ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? 'HorusDrive sẵn sàng' : 'Chưa cấu hình HorusDrive',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  ready ? '$account / ${_settings.remoteFolder}' : 'Có thể ghi âm và chia sẻ file mà không cần cấu hình',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton.icon(onPressed: _openSettings, icon: const Icon(Icons.tune_outlined), label: const Text('Sửa')),
        ],
      ),
    );
  }

  Widget _buildRecorderCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = _selectedLabel;
    final statusText = _isRecording
        ? _isPaused
              ? 'Tạm dừng'
              : 'Đang ghi'
        : 'Sẵn sàng';
    final statusColor = _isRecording ? scheme.error : const Color(0xFF0D6B3F);

    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ghi âm',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                _StatusPill(
                  icon: _isRecording ? Icons.fiber_manual_record : Icons.check_circle_outline,
                  text: statusText,
                  color: statusColor,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              _formatDuration(_elapsed),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: _isRecording ? scheme.error : scheme.onSurface,
              ),
            ),
            const SizedBox(height: 16),
            _LiveWaveform(
              samples: _waveSamples,
              active: _isRecording && !_isPaused,
              color: _isRecording ? scheme.error : scheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              label == null ? 'Chưa có nhãn' : 'Nhãn: ${label.name}',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: _isRecording ? scheme.error : scheme.primary,
                foregroundColor: _isRecording ? scheme.onError : scheme.onPrimary,
              ),
              onPressed: _busy
                  ? null
                  : _isRecording
                  ? _stopRecording
                  : _startRecording,
              icon: Icon(_isRecording ? Icons.stop : Icons.mic),
              label: Text(_isRecording ? 'Dừng ghi' : 'Bắt đầu ghi'),
            ),
            if (_isRecording) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy ? null : _togglePause,
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                label: Text(_isPaused ? 'Tiếp tục' : 'Tạm dừng'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLabelsCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedLabel;

    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Nhãn',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Thêm nhãn',
                  onPressed: () => _openLabelEditor(),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final label in _labels)
                  ChoiceChip(
                    label: Text(label.name),
                    selected: label.id == selected?.id,
                    onSelected: (_) {
                      setState(() => _selectedLabelId = label.id);
                    },
                  ),
              ],
            ),
            if (selected != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _openLabelEditor(label: selected),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Sửa nhãn'),
                  ),
                  TextButton.icon(
                    onPressed: _deleteSelectedLabel,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Xoá nhãn'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Bản ghi', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        if (_recordings.isEmpty)
          _buildEmptyRecordings(context)
        else
          for (final recording in _recordings) ...[_buildRecordingCard(context, recording), const SizedBox(height: 12)],
      ],
    );
  }

  Widget _buildEmptyRecordings(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.mic_none_outlined, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Chưa có bản ghi',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingCard(BuildContext context, RecordingItem recording) {
    final scheme = Theme.of(context).colorScheme;
    final uploading = _uploadingIds.contains(recording.id);
    final linking = _linkingIds.contains(recording.id);
    final sharing = _sharingIds.contains(recording.id);
    final playbackLoaded = _loadedPlaybackId == recording.id;
    final playbackPlaying = _playingRecordingId == recording.id;
    final duration = playbackLoaded && _playbackDuration > Duration.zero ? _playbackDuration : recording.duration;
    final position = playbackLoaded ? _playbackPosition : Duration.zero;
    final positionMs = position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();
    final durationMs = duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final statusColor = uploading
        ? scheme.primary
        : recording.isUploaded
        ? const Color(0xFF0D6B3F)
        : recording.uploadError != null
        ? scheme.error
        : scheme.onSurfaceVariant;
    final statusIcon = uploading
        ? Icons.sync
        : recording.isUploaded
        ? Icons.cloud_done_outlined
        : recording.uploadError != null
        ? Icons.cloud_upload_outlined
        : Icons.phone_android_outlined;
    final statusText = uploading
        ? 'Đang tải'
        : recording.isUploaded
        ? 'Đã tải'
        : recording.uploadError != null
        ? 'Lỗi tải lên'
        : 'Đã lưu trên máy';

    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    recording.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusPill(icon: statusIcon, text: statusText, color: statusColor),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${recording.label} • ${_formatDateTime(recording.startedAt)} - ${_formatTime(recording.endedAt)} • ${_formatDuration(recording.duration)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (recording.uploadError != null) ...[
              const SizedBox(height: 8),
              Text(
                recording.uploadError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: playbackPlaying ? 'Tạm dừng nghe' : 'Nghe lại',
                  onPressed: _playbackBusy ? null : () => _togglePlayback(recording),
                  icon: Icon(playbackPlaying ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: playbackLoaded
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              ),
                              child: Slider(
                                min: 0,
                                max: durationMs,
                                value: positionMs,
                                onChanged: (value) {
                                  setState(() {
                                    _playbackPosition = Duration(milliseconds: value.round());
                                  });
                                },
                                onChangeEnd: _seekPlayback,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(
                                '${_formatDuration(position)} / ${_formatDuration(duration)}',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        )
                      : Text(
                          'Nghe lại',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: 'Chia sẻ bản ghi âm',
                    onPressed: sharing ? null : () => _shareRecording(recording, buttonContext),
                    icon: const Icon(Icons.share_outlined),
                  ),
                ),
                if (!recording.isUploaded)
                  IconButton(
                    tooltip: 'Tải lên HorusDrive',
                    onPressed: uploading ? null : () => _uploadRecording(recording, showSuccess: true),
                    icon: const Icon(Icons.cloud_upload_outlined),
                  ),
                if (recording.isUploaded || recording.shareLink != null || recording.remotePath != null)
                  IconButton(
                    tooltip: 'Copy link âm thanh',
                    onPressed: linking ? null : () => _copyRecordingLink(recording),
                    icon: linking
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link_outlined),
                  ),
                IconButton(
                  tooltip: 'Xoá bản ghi local',
                  onPressed: uploading || sharing ? null : () => _deleteRecording(recording),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveWaveform extends StatelessWidget {
  const _LiveWaveform({required this.samples, required this.active, required this.color});

  final List<double> samples;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: active ? 'Sóng âm đang ghi' : 'Sóng âm tạm dừng',
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.10) : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.16) : scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _WaveformPainter(samples: samples, color: active ? color : scheme.onSurfaceVariant),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) {
      return;
    }

    final centerY = size.height / 2;
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(12, centerY), Offset(size.width - 12, centerY), linePaint);

    final barWidth = (size.width / (samples.length * 2.35)).clamp(2.5, 4.2);
    final gap = ((size.width - 24 - samples.length * barWidth) / (samples.length - 1)).clamp(1.8, 5.0);
    final totalWidth = samples.length * barWidth + (samples.length - 1) * gap;
    var x = (size.width - totalWidth) / 2;
    final maxBarHeight = size.height - 18;
    final paint = Paint();

    for (var index = 0; index < samples.length; index += 1) {
      final sample = samples[index].clamp(0.08, 1.0);
      final age = (index + 1) / samples.length;
      final envelope = 0.72 + 0.28 * math.sin(age * math.pi);
      final flutter = 1 + 0.1 * math.sin(index * 1.73 + sample * 6.0);
      final shaped = (math.pow(sample, 0.72) * envelope * flutter).clamp(0.08, 1.0);
      final height = 8 + (maxBarHeight - 8) * shaped;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, centerY - height / 2, barWidth, height),
        Radius.circular(barWidth),
      );
      paint.color = color.withValues(alpha: 0.22 + 0.62 * age);
      canvas.drawRRect(rect, paint);

      if (sample > 0.58) {
        final glowPaint = Paint()
          ..color = color.withValues(alpha: 0.08 * sample)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
        canvas.drawRRect(rect.inflate(2), glowPaint);
      }

      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.samples != samples || oldDelegate.color != color;
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _SelectRecordingLabelDialog extends StatefulWidget {
  const _SelectRecordingLabelDialog({required this.labels, required this.initialLabelId, required this.newLabelId});

  final List<LabelItem> labels;
  final String? initialLabelId;
  final String Function() newLabelId;

  @override
  State<_SelectRecordingLabelDialog> createState() => _SelectRecordingLabelDialogState();
}

class _SelectRecordingLabelDialogState extends State<_SelectRecordingLabelDialog> {
  late final TextEditingController _newLabelController;
  late List<LabelItem> _labels;
  String? _selectedLabelId;
  String? _newLabelError;

  @override
  void initState() {
    super.initState();
    _newLabelController = TextEditingController();
    _labels = [...widget.labels];
    final initialExists = _labels.any((label) => label.id == widget.initialLabelId);
    _selectedLabelId = initialExists
        ? widget.initialLabelId!
        : _labels.isEmpty
        ? null
        : _labels.first.id;
  }

  @override
  void dispose() {
    _newLabelController.dispose();
    super.dispose();
  }

  void _addLabel() {
    final name = _newLabelController.text.trim();
    if (name.isEmpty) {
      setState(() => _newLabelError = 'Nhập tên nhãn');
      return;
    }

    final normalized = name.toLowerCase();
    final duplicated = _labels.any((label) => label.name.trim().toLowerCase() == normalized);
    if (duplicated) {
      setState(() => _newLabelError = 'Nhãn đã tồn tại');
      return;
    }

    final label = LabelItem(id: widget.newLabelId(), name: name);
    setState(() {
      _labels = [..._labels, label];
      _selectedLabelId = label.id;
      _newLabelController.clear();
      _newLabelError = null;
    });
  }

  LabelItem? get _selectedLabel {
    final selectedLabelId = _selectedLabelId;
    if (selectedLabelId == null || _labels.isEmpty) {
      return null;
    }
    return _labels.firstWhere((label) => label.id == selectedLabelId, orElse: () => _labels.first);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Chọn nhãn ghi âm'),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _labels.isEmpty ? 56 : math.min(_labels.length * 56.0, 280.0),
              child: _labels.isEmpty
                  ? Center(
                      child: Text(
                        'Chưa có nhãn',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  : RadioGroup<String>(
                      groupValue: _selectedLabelId,
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _selectedLabelId = value);
                      },
                      child: ListView(
                        children: [
                          for (final label in _labels) RadioListTile<String>(value: label.id, title: Text(label.name)),
                        ],
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newLabelController,
                      decoration: InputDecoration(labelText: 'Nhãn mới', errorText: _newLabelError),
                      textInputAction: TextInputAction.done,
                      onChanged: (_) {
                        if (_newLabelError != null) {
                          setState(() => _newLabelError = null);
                        }
                      },
                      onSubmitted: (_) => _addLabel(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(tooltip: 'Thêm nhãn', onPressed: _addLabel, icon: const Icon(Icons.add)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Hủy')),
        FilledButton.icon(
          onPressed: _selectedLabel == null ? null : () => Navigator.of(context).pop(_selectedLabel),
          icon: const Icon(Icons.mic),
          label: const Text('OK'),
        ),
      ],
    );
  }
}

class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.title, required this.initialName, required this.existingNames});

  final String title;
  final String initialName;
  final Set<String> existingNames;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Tên nhãn'),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) {
              return 'Nhập tên nhãn';
            }
            if (widget.existingNames.contains(name.toLowerCase())) {
              return 'Nhãn đã tồn tại';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Hủy')),
        FilledButton(onPressed: _submit, child: const Text('Lưu')),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.settings, required this.onTest});

  final HorusSettings settings;
  final Future<String?> Function(HorusSettings settings) onTest;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _folderController;
  late HorusAuthMode _authMode;
  bool _obscurePassword = true;
  bool _testing = false;
  bool? _testSucceeded;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: widget.settings.serverUrl);
    _usernameController = TextEditingController(text: widget.settings.username);
    _passwordController = TextEditingController(text: widget.settings.password);
    _folderController = TextEditingController(text: widget.settings.remoteFolder);
    _authMode = widget.settings.authMode;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cài đặt HorusDrive'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _serverController,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Server URL'),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) {
                    return 'Nhập server URL';
                  }
                  final normalized = text.startsWith('http') ? text : 'https://$text';
                  final uri = Uri.tryParse(normalized);
                  if (uri == null || !uri.hasAuthority) {
                    return 'URL chưa đúng';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<HorusAuthMode>(
                  segments: const [
                    ButtonSegment(value: HorusAuthMode.basic, label: Text('Basic'), icon: Icon(Icons.key_outlined)),
                    ButtonSegment(value: HorusAuthMode.bearer, label: Text('Bearer'), icon: Icon(Icons.token_outlined)),
                  ],
                  selected: {_authMode},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _authMode = selected.first;
                      _testSucceeded = null;
                      _testMessage = null;
                    });
                  },
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _usernameController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: _authMode == HorusAuthMode.basic ? 'Username' : 'Username / user id',
                ),
                validator: (value) {
                  if (_authMode == HorusAuthMode.basic && (value?.trim() ?? '').isEmpty) {
                    return 'Nhập username';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: _authMode == HorusAuthMode.basic ? 'Password / app password' : 'Bearer token',
                  suffixIcon: IconButton(
                    tooltip: _obscurePassword ? 'Hiện password' : 'Ẩn password',
                    onPressed: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                    icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  ),
                ),
                validator: (value) {
                  if ((value?.trim() ?? '').isEmpty) {
                    return _authMode == HorusAuthMode.basic ? 'Nhập password' : 'Nhập Bearer token';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _folderController,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Thư mục remote'),
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_testMessage != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _testSucceeded == true ? Icons.check_circle_outline : Icons.error_outline,
                      color: _testSucceeded == true ? const Color(0xFF0D6B3F) : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _testMessage!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _testSucceeded == true ? const Color(0xFF0D6B3F) : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Huỷ')),
        TextButton.icon(
          onPressed: _testing ? null : _testConnection,
          icon: _testing
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering_outlined),
          label: const Text('Kiểm tra'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Lưu')),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    Navigator.of(context).pop(_settingsFromForm());
  }

  Future<void> _testConnection() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }

    setState(() {
      _testing = true;
      _testSucceeded = null;
      _testMessage = null;
    });

    final error = await widget.onTest(_settingsFromForm());
    if (!mounted) {
      return;
    }
    setState(() {
      _testing = false;
      _testSucceeded = error == null;
      _testMessage = error ?? 'Kết nối HorusDrive OK';
    });
  }

  HorusSettings _settingsFromForm() {
    return HorusSettings(
      serverUrl: _serverController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text.trim(),
      remoteFolder: _folderController.text.trim(),
      authMode: _authMode,
    );
  }
}
