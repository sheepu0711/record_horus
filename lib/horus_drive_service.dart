import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'app_models.dart';

class HorusUploadResult {
  const HorusUploadResult({
    required this.remotePath,
    required this.statusCode,
    this.shareLink,
  });

  final String remotePath;
  final int statusCode;
  final String? shareLink;
}

class HorusDriveException implements Exception {
  HorusDriveException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    if (statusCode == null) {
      return message;
    }
    return '$message ($statusCode)';
  }
}

class HorusDriveService {
  HorusDriveService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  void close() {
    _client.close();
  }

  Future<void> checkConnection(HorusSettings settings) async {
    if (!settings.hasUploadCredentials) {
      throw HorusDriveException('Chưa cấu hình HorusDrive');
    }

    HorusDriveException? lastError;
    for (final endpoint in _candidateEndpoints(settings)) {
      try {
        final uri = _buildDavUri(settings, endpoint: endpoint);
        final request = http.Request('PROPFIND', uri)
          ..headers.addAll({..._headers(settings), 'Depth': '0'});
        final streamed = await _client.send(request);
        final response = await http.Response.fromStream(streamed);
        if (!_isSuccess(response.statusCode)) {
          throw HorusDriveException(
            _messageForStatus(response.statusCode, response.body),
            statusCode: response.statusCode,
          );
        }
        return;
      } on HorusDriveException catch (error) {
        lastError = error;
        if (!_canTryFallbackEndpoint(error)) {
          rethrow;
        }
      }
    }

    throw lastError ?? HorusDriveException('Không kết nối được HorusDrive');
  }

  Future<String> getRecordingLink({
    required HorusSettings settings,
    required RecordingItem recording,
  }) async {
    if (!settings.hasUploadCredentials) {
      throw HorusDriveException('Chưa cấu hình HorusDrive');
    }

    final folderSegments = _splitRemoteFolder(settings.remoteFolder);
    final shareLink = await _getOrCreateShareLink(settings, [
      ...folderSegments,
      recording.fileName,
    ]);

    if (shareLink != null && shareLink.isNotEmpty) {
      return shareLink;
    }

    if (recording.remotePath != null && recording.remotePath!.isNotEmpty) {
      return recording.remotePath!;
    }

    throw HorusDriveException('Chưa lấy được link cho file này');
  }

  Future<HorusUploadResult> uploadRecording({
    required HorusSettings settings,
    required RecordingItem recording,
  }) async {
    if (!settings.hasUploadCredentials) {
      throw HorusDriveException('Chưa cấu hình HorusDrive');
    }

    final file = File(recording.filePath);
    if (!await file.exists()) {
      throw HorusDriveException('Không tìm thấy file local');
    }

    final folderSegments = _splitRemoteFolder(settings.remoteFolder);
    final audioBytes = await file.readAsBytes();

    HorusDriveException? lastError;
    for (final endpoint in _candidateEndpoints(settings)) {
      try {
        await _ensureRemoteFolder(settings, folderSegments, endpoint);

        final remoteUri = _buildDavUri(
          settings,
          endpoint: endpoint,
          pathSegments: [...folderSegments, recording.fileName],
        );
        final request = http.Request('PUT', remoteUri)
          ..headers.addAll(_headers(settings, contentType: 'audio/mp4'))
          ..bodyBytes = audioBytes;

        final streamed = await _client.send(request);
        final response = await http.Response.fromStream(streamed);
        if (!_isSuccess(response.statusCode)) {
          throw HorusDriveException(
            _messageForStatus(response.statusCode, response.body),
            statusCode: response.statusCode,
          );
        }

        final remoteSegments = [...folderSegments, recording.fileName];
        final shareLink = await _getOrCreateShareLink(settings, remoteSegments);

        return HorusUploadResult(
          remotePath: remoteUri.toString(),
          statusCode: response.statusCode,
          shareLink: shareLink,
        );
      } on HorusDriveException catch (error) {
        lastError = error;
        if (!_canTryFallbackEndpoint(error)) {
          rethrow;
        }
      }
    }

    throw lastError ?? HorusDriveException('Không tải lên được HorusDrive');
  }

  Future<void> _ensureRemoteFolder(
    HorusSettings settings,
    List<String> folderSegments,
    _WebDavEndpoint endpoint,
  ) async {
    final current = <String>[];
    for (final segment in folderSegments) {
      current.add(segment);
      final uri = _buildDavUri(
        settings,
        endpoint: endpoint,
        pathSegments: current,
      );
      final request = http.Request('MKCOL', uri)
        ..headers.addAll(_headers(settings));
      final streamed = await _client.send(request);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 201 ||
          response.statusCode == 200 ||
          response.statusCode == 405) {
        continue;
      }

      throw HorusDriveException(
        _messageForStatus(response.statusCode, response.body),
        statusCode: response.statusCode,
      );
    }
  }

  Future<String?> _getOrCreateShareLink(
    HorusSettings settings,
    List<String> remotePathSegments,
  ) async {
    final existingLink = await _findShareLink(settings, remotePathSegments);
    if (existingLink != null) {
      return existingLink;
    }

    final createUri = _buildOcsSharesUri(settings);
    final request = http.Request('POST', createUri)
      ..headers.addAll(_ocsHeaders(settings))
      ..body = Uri(
        queryParameters: {
          'path': _sharePath(remotePathSegments),
          'shareType': '3',
          'permissions': '1',
        },
      ).query;

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (!_isSuccess(response.statusCode)) {
      return _findShareLink(settings, remotePathSegments);
    }

    return _shareUrlFromOcs(response.body) ??
        _findShareLink(settings, remotePathSegments);
  }

  Future<String?> _findShareLink(
    HorusSettings settings,
    List<String> remotePathSegments,
  ) async {
    final uri = _buildOcsSharesUri(
      settings,
      queryParameters: {
        'format': 'json',
        'path': _sharePath(remotePathSegments),
        'reshares': 'true',
      },
    );
    final request = http.Request('GET', uri)
      ..headers.addAll(_ocsHeaders(settings, includeContentType: false));

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (!_isSuccess(response.statusCode)) {
      return null;
    }

    return _shareUrlFromOcs(response.body);
  }

  Uri _buildDavUri(
    HorusSettings settings, {
    required _WebDavEndpoint endpoint,
    List<String> pathSegments = const [],
  }) {
    final server = _parseServer(settings.serverUrl);
    final serverSegments = server.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final endpointSegments = switch (endpoint) {
      _WebDavEndpoint.userDav => [
        'remote.php',
        'dav',
        'files',
        settings.username.trim(),
      ],
      _WebDavEndpoint.webdav => ['remote.php', 'webdav'],
    };

    return server.replace(
      pathSegments: [...serverSegments, ...endpointSegments, ...pathSegments],
      query: null,
      fragment: null,
    );
  }

  Uri _buildOcsSharesUri(
    HorusSettings settings, {
    Map<String, String> queryParameters = const {'format': 'json'},
  }) {
    final server = _parseServer(settings.serverUrl);
    final serverSegments = server.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return server.replace(
      pathSegments: [
        ...serverSegments,
        'ocs',
        'v2.php',
        'apps',
        'files_sharing',
        'api',
        'v1',
        'shares',
      ],
      queryParameters: queryParameters,
      fragment: null,
    );
  }

  Uri _parseServer(String value) {
    final trimmed = value.trim();
    final withScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
    return Uri.parse(withScheme);
  }

  List<String> _splitRemoteFolder(String folder) {
    return folder
        .split(RegExp(r'[\\/]'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
  }

  Map<String, String> _headers(HorusSettings settings, {String? contentType}) {
    final headers = <String, String>{};
    switch (settings.authMode) {
      case HorusAuthMode.basic:
        final token = base64Encode(
          utf8.encode(
            '${settings.username.trim()}:${settings.password.trim()}',
          ),
        );
        headers['Authorization'] = 'Basic $token';
        break;
      case HorusAuthMode.bearer:
        headers['Authorization'] = 'Bearer ${settings.password.trim()}';
        break;
    }
    if (contentType != null) {
      headers['Content-Type'] = contentType;
    }
    return headers;
  }

  Map<String, String> _ocsHeaders(
    HorusSettings settings, {
    bool includeContentType = true,
  }) {
    final headers = {
      ..._headers(settings),
      'OCS-APIRequest': 'true',
      'Accept': 'application/json',
    };
    if (includeContentType) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return headers;
  }

  String _sharePath(List<String> pathSegments) {
    return '/${pathSegments.map((segment) => segment.trim()).join('/')}';
  }

  String? _shareUrlFromOcs(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }

    final ocs = decoded['ocs'];
    if (ocs is! Map) {
      return null;
    }

    return _shareUrlFromData(ocs['data']);
  }

  String? _shareUrlFromData(Object? data) {
    if (data is Map) {
      final url = data['url'];
      if (url is String && url.isNotEmpty) {
        return url;
      }
      final nestedData = data['data'];
      if (nestedData != null) {
        return _shareUrlFromData(nestedData);
      }
    }

    if (data is List) {
      for (final item in data) {
        final url = _shareUrlFromData(item);
        if (url != null && url.isNotEmpty) {
          return url;
        }
      }
    }

    return null;
  }

  List<_WebDavEndpoint> _candidateEndpoints(HorusSettings settings) {
    if (settings.username.trim().isEmpty) {
      return const [_WebDavEndpoint.webdav];
    }
    return _WebDavEndpoint.values;
  }

  bool _canTryFallbackEndpoint(HorusDriveException error) {
    return switch (error.statusCode) {
      401 || 403 || 404 || 409 => true,
      _ => false,
    };
  }

  bool _isSuccess(int statusCode) {
    return statusCode >= 200 && statusCode < 300;
  }

  String _messageForStatus(int statusCode, String body) {
    final serverMessage = _shortBody(body);
    final suffix = serverMessage.isEmpty ? '' : ': $serverMessage';
    return switch (statusCode) {
      401 || 403 => 'Không đăng nhập được HorusDrive$suffix',
      404 => 'Không tìm thấy WebDAV trên HorusDrive$suffix',
      409 => 'Thư mục HorusDrive chưa sẵn sàng$suffix',
      507 => 'HorusDrive đã hết dung lượng$suffix',
      _ => 'HorusDrive trả về lỗi$suffix',
    };
  }

  String _shortBody(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final messageMatch = RegExp(
      r'<s:message>([^<]+)</s:message>',
      caseSensitive: false,
    ).firstMatch(compact);
    if (messageMatch != null) {
      return _cleanServerMessage(messageMatch.group(1) ?? '');
    }
    if (compact.startsWith('<?xml') || compact.startsWith('<d:error')) {
      return '';
    }
    if (compact.length <= 160) {
      return _cleanServerMessage(compact);
    }
    return '${_cleanServerMessage(compact.substring(0, 160))}...';
  }

  String _cleanServerMessage(String message) {
    final compact = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final marker in const [
      ", No 'Authorization: Bearer' header",
      ', No "Authorization: Bearer" header',
    ]) {
      final markerIndex = compact.indexOf(marker);
      if (markerIndex > 0) {
        return compact.substring(0, markerIndex);
      }
    }
    return compact;
  }
}

enum _WebDavEndpoint { userDav, webdav }
