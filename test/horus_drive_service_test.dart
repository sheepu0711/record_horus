import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record_horus/app_models.dart';
import 'package:record_horus/horus_drive_service.dart';

void main() {
  test(
    'falls back to legacy webdav endpoint when user dav endpoint rejects',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'record_horus_test',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}test.m4a',
      );
      await localFile.writeAsBytes([1, 2, 3]);

      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/remote.php/dav/files/hieunt/RecordHorus') {
          return http.Response(
            '<?xml version="1.0"?><d:error xmlns:d="DAV:" />',
            401,
          );
        }
        if (path == '/remote.php/webdav/RecordHorus') {
          return http.Response('', 201);
        }
        if (path == '/remote.php/webdav/RecordHorus/test.m4a') {
          return http.Response('', 201);
        }
        if (path == '/ocs/v2.php/apps/files_sharing/api/v1/shares' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200},
                'data': [],
              },
            }),
            200,
          );
        }
        if (path == '/ocs/v2.php/apps/files_sharing/api/v1/shares' &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200},
                'data': {'url': 'https://drive.example.com/s/public-link'},
              },
            }),
            200,
          );
        }
        return http.Response('unexpected $path', 500);
      });

      final service = HorusDriveService(client: client);
      final result = await service.uploadRecording(
        settings: const HorusSettings(
          serverUrl: 'https://drive.example.com',
          username: 'hieunt',
          password: ' app-password ',
          remoteFolder: 'RecordHorus',
        ),
        recording: RecordingItem(
          id: '1',
          label: 'Chung',
          startedAt: DateTime(2026),
          endedAt: DateTime(2026, 1, 1, 0, 1),
          filePath: localFile.path,
          fileName: 'test.m4a',
        ),
      );

      final expectedAuth =
          'Basic ${base64Encode(utf8.encode('hieunt:app-password'))}';
      expect(
        result.remotePath,
        'https://drive.example.com/remote.php/webdav/RecordHorus/test.m4a',
      );
      expect(result.shareLink, 'https://drive.example.com/s/public-link');
      expect(
        requests.map((request) => '${request.method} ${request.url.path}'),
        [
          'MKCOL /remote.php/dav/files/hieunt/RecordHorus',
          'MKCOL /remote.php/webdav/RecordHorus',
          'PUT /remote.php/webdav/RecordHorus/test.m4a',
          'GET /ocs/v2.php/apps/files_sharing/api/v1/shares',
          'POST /ocs/v2.php/apps/files_sharing/api/v1/shares',
        ],
      );
      expect(
        requests.last.body,
        'path=%2FRecordHorus%2Ftest.m4a&shareType=3&permissions=1',
      );
      expect(requests.last.headers['Authorization'], expectedAuth);
    },
  );

  test('falls back when user dav folder parent does not exist', () async {
    final tempDir = await Directory.systemTemp.createTemp('record_horus_test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final localFile = File('${tempDir.path}${Platform.pathSeparator}test.m4a');
    await localFile.writeAsBytes([1, 2, 3]);

    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/remote.php/dav/files/hieunt/RecordHorus') {
        return http.Response(
          '<?xml version="1.0"?><d:error xmlns:d="DAV:"><s:message xmlns:s="http://sabredav.org/ns">parent node does not exist</s:message></d:error>',
          409,
        );
      }
      if (path == '/remote.php/webdav/RecordHorus') {
        return http.Response('', 201);
      }
      if (path == '/remote.php/webdav/RecordHorus/test.m4a') {
        return http.Response('', 201);
      }
      if (path == '/ocs/v2.php/apps/files_sharing/api/v1/shares' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': [],
            },
          }),
          200,
        );
      }
      if (path == '/ocs/v2.php/apps/files_sharing/api/v1/shares' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': {'url': 'https://drive.example.com/s/public-link'},
            },
          }),
          200,
        );
      }
      return http.Response('unexpected $path', 500);
    });

    final service = HorusDriveService(client: client);
    final result = await service.uploadRecording(
      settings: const HorusSettings(
        serverUrl: 'https://drive.example.com',
        username: 'hieunt',
        password: 'app-password',
        remoteFolder: 'RecordHorus',
      ),
      recording: RecordingItem(
        id: '1',
        label: 'Chung',
        startedAt: DateTime(2026),
        endedAt: DateTime(2026, 1, 1, 0, 1),
        filePath: localFile.path,
        fileName: 'test.m4a',
      ),
    );

    expect(
      result.remotePath,
      'https://drive.example.com/remote.php/webdav/RecordHorus/test.m4a',
    );
    expect(requests.map((request) => '${request.method} ${request.url.path}'), [
      'MKCOL /remote.php/dav/files/hieunt/RecordHorus',
      'MKCOL /remote.php/webdav/RecordHorus',
      'PUT /remote.php/webdav/RecordHorus/test.m4a',
      'GET /ocs/v2.php/apps/files_sharing/api/v1/shares',
      'POST /ocs/v2.php/apps/files_sharing/api/v1/shares',
    ]);
  });

  test('uses bearer token when bearer auth mode is selected', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('', 207);
    });

    final service = HorusDriveService(client: client);
    await service.checkConnection(
      const HorusSettings(
        serverUrl: 'https://drive.example.com',
        username: '',
        password: ' bearer-token ',
        remoteFolder: 'RecordHorus',
        authMode: HorusAuthMode.bearer,
      ),
    );

    expect(requests.single.url.path, '/remote.php/webdav');
    expect(requests.single.headers['Authorization'], 'Bearer bearer-token');
  });
}
