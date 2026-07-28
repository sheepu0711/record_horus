const defaultHorusServerUrl = String.fromEnvironment(
  'HORUS_SERVER_URL',
  defaultValue: 'https://drive.horusvn.com',
);
const defaultHorusUsername = String.fromEnvironment(
  'HORUS_USERNAME',
  defaultValue: 'hieunt',
);
const defaultHorusPassword = String.fromEnvironment('HORUS_PASSWORD');
const defaultHorusFolder = String.fromEnvironment(
  'HORUS_FOLDER',
  defaultValue: 'RecordHorus',
);

enum HorusAuthMode {
  basic('basic'),
  bearer('bearer');

  const HorusAuthMode(this.code);

  final String code;

  static HorusAuthMode fromCode(String? code) {
    return HorusAuthMode.values.firstWhere(
      (mode) => mode.code == code,
      orElse: () => HorusAuthMode.basic,
    );
  }
}

class LabelItem {
  const LabelItem({required this.id, required this.name});

  final String id;
  final String name;

  LabelItem copyWith({String? name}) {
    return LabelItem(id: id, name: name ?? this.name);
  }

  Map<String, Object?> toJson() {
    return {'id': id, 'name': name};
  }

  factory LabelItem.fromJson(Map<String, Object?> json) {
    return LabelItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}

class RecordingItem {
  const RecordingItem({
    required this.id,
    required this.label,
    required this.startedAt,
    required this.endedAt,
    required this.filePath,
    required this.fileName,
    this.uploadedAt,
    this.remotePath,
    this.uploadError,
  });

  final String id;
  final String label;
  final DateTime startedAt;
  final DateTime endedAt;
  final String filePath;
  final String fileName;
  final DateTime? uploadedAt;
  final String? remotePath;
  final String? uploadError;

  bool get isUploaded => uploadedAt != null && uploadError == null;

  Duration get duration => endedAt.difference(startedAt);

  String get title {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex <= 0) {
      return fileName;
    }
    return fileName.substring(0, dotIndex);
  }

  RecordingItem copyWith({
    String? label,
    DateTime? startedAt,
    DateTime? endedAt,
    String? filePath,
    String? fileName,
    DateTime? uploadedAt,
    String? remotePath,
    String? uploadError,
    bool clearUploadedAt = false,
    bool clearRemotePath = false,
    bool clearUploadError = false,
  }) {
    return RecordingItem(
      id: id,
      label: label ?? this.label,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      uploadedAt: clearUploadedAt ? null : uploadedAt ?? this.uploadedAt,
      remotePath: clearRemotePath ? null : remotePath ?? this.remotePath,
      uploadError: clearUploadError ? null : uploadError ?? this.uploadError,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'label': label,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'filePath': filePath,
      'fileName': fileName,
      'uploadedAt': uploadedAt?.toIso8601String(),
      'remotePath': remotePath,
      'uploadError': uploadError,
    };
  }

  factory RecordingItem.fromJson(Map<String, Object?> json) {
    return RecordingItem(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      endedAt:
          DateTime.tryParse(json['endedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      filePath: json['filePath'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      uploadedAt: DateTime.tryParse(json['uploadedAt'] as String? ?? ''),
      remotePath: json['remotePath'] as String?,
      uploadError: json['uploadError'] as String?,
    );
  }
}

class HorusSettings {
  const HorusSettings({
    required this.serverUrl,
    required this.username,
    required this.remoteFolder,
    this.authMode = HorusAuthMode.basic,
    this.password = '',
  });

  final String serverUrl;
  final String username;
  final String remoteFolder;
  final HorusAuthMode authMode;
  final String password;

  bool get hasUploadCredentials {
    if (serverUrl.trim().isEmpty || password.trim().isEmpty) {
      return false;
    }
    return authMode == HorusAuthMode.bearer || username.trim().isNotEmpty;
  }

  HorusSettings copyWith({
    String? serverUrl,
    String? username,
    String? remoteFolder,
    HorusAuthMode? authMode,
    String? password,
  }) {
    return HorusSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      remoteFolder: remoteFolder ?? this.remoteFolder,
      authMode: authMode ?? this.authMode,
      password: password ?? this.password,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'remoteFolder': remoteFolder,
      'authMode': authMode.code,
    };
  }

  factory HorusSettings.fromJson(Map<String, Object?> json) {
    return HorusSettings(
      serverUrl: json['serverUrl'] as String? ?? defaultHorusServerUrl,
      username: json['username'] as String? ?? defaultHorusUsername,
      remoteFolder: json['remoteFolder'] as String? ?? defaultHorusFolder,
      authMode: HorusAuthMode.fromCode(json['authMode'] as String?),
    );
  }

  factory HorusSettings.defaults({String password = defaultHorusPassword}) {
    return HorusSettings(
      serverUrl: defaultHorusServerUrl,
      username: defaultHorusUsername,
      remoteFolder: defaultHorusFolder,
      authMode: HorusAuthMode.basic,
      password: password,
    );
  }
}
