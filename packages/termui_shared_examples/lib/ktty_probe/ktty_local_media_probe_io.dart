import 'dart:io';
import 'dart:math';

import 'ktty_probe_report.dart';

const List<int> _kttyLocalProbeRgbaBytes = [
  40, 210, 255, 255, 255, 110, 190, 255, //
  110, 255, 170, 255, 255, 220, 90, 255,
];

int _probeSessionSeq = 0;
final Random _probeNonceRandom = Random.secure();

String _nextNonce() {
  _probeSessionSeq++;
  final rand = _probeNonceRandom.nextInt(1 << 30).toRadixString(16);
  return '$pid-$_probeSessionSeq-$rand';
}

bool _isRegularFileNoFollow(String? path) =>
    path != null &&
    FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.file;

File? _writeFreshFixture(String path) {
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return null;
    }
    final file = File(path);
    file.writeAsBytesSync(_kttyLocalProbeRgbaBytes, flush: true);
    return file;
  } on FileSystemException {
    return null;
  }
}

void _deleteFileSafely(File? file) {
  if (file == null || !_isRegularFileNoFollow(file.path)) return;
  try {
    file.deleteSync();
  } on FileSystemException {
    // Ignore cleanup errors if the terminal or OS already unlinked the artifact.
  }
}

void _deleteDirSafely(Directory? dir) {
  if (dir == null) return;
  try {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  } on FileSystemException {
    // Ignore cleanup errors if already removed.
  }
}

final class _IoLocalMediaProbeSession implements KttyLocalMediaProbeSession {
  final Directory? _tempDir;
  final File? _tempFile;
  final File? _shmFile;

  @override
  final String? tempFilePath;

  @override
  final String? shmObjectName;

  const _IoLocalMediaProbeSession({
    required Directory? tempDir,
    required File? tempFile,
    required this.tempFilePath,
    required File? shmFile,
    required this.shmObjectName,
  }) : _tempDir = tempDir,
       _tempFile = tempFile,
       _shmFile = shmFile;

  @override
  bool get tempFileStillExists => _isRegularFileNoFollow(_tempFile?.path);

  @override
  bool get shmStillExists => _isRegularFileNoFollow(_shmFile?.path);

  @override
  void dispose() {
    _deleteFileSafely(_tempFile);
    _deleteDirSafely(_tempDir);
    _deleteFileSafely(_shmFile);
  }
}

/// Creates local temporary-file (`t=t`) and Linux `/dev/shm` (`t=s`) 2x2 RGBA
/// fixtures for non-destructive Kitty Graphics `a=q` medium probes.
KttyLocalMediaProbeSession createLocalMediaProbeSession() {
  Directory? tempDir;
  File? tempFile;
  try {
    tempDir = Directory.systemTemp.createTempSync(
      'tty-graphics-protocol-ktty-probe-',
    );
    final sep = Platform.pathSeparator;
    final base = tempDir.path.endsWith(sep)
        ? tempDir.path.substring(0, tempDir.path.length - 1)
        : tempDir.path;
    tempFile = _writeFreshFixture('$base${sep}probe.rgba');
    if (tempFile == null) {
      _deleteDirSafely(tempDir);
      tempDir = null;
    }
  } on FileSystemException {
    _deleteDirSafely(tempDir);
    tempDir = null;
    tempFile = null;
  }

  File? shmFile;
  String? shmObjectName;
  if (Platform.isLinux && Directory('/dev/shm').existsSync()) {
    final shmBasename = 'tty-graphics-protocol-ktty-probe-${_nextNonce()}';
    shmFile = _writeFreshFixture('/dev/shm/$shmBasename');
    if (shmFile != null) {
      shmObjectName = '/$shmBasename';
    }
  }

  return _IoLocalMediaProbeSession(
    tempDir: tempDir,
    tempFile: tempFile,
    tempFilePath: tempFile?.path,
    shmFile: shmFile,
    shmObjectName: shmObjectName,
  );
}
