// ignore_for_file: public_member_api_docs

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/impl/conpty_bundle.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:win32/win32.dart' as win32;

typedef _CreatePseudoConsoleNative =
    Int32 Function(
      win32.COORD size,
      Pointer hInput,
      Pointer hOutput,
      Uint32 dwFlags,
      Pointer<IntPtr> phPC,
    );
typedef _CreatePseudoConsoleDart =
    int Function(
      win32.COORD size,
      Pointer hInput,
      Pointer hOutput,
      int dwFlags,
      Pointer<IntPtr> phPC,
    );

typedef _ResizePseudoConsoleNative =
    Int32 Function(IntPtr hPC, win32.COORD size);
typedef _ResizePseudoConsoleDart = int Function(int hPC, win32.COORD size);

typedef _ClosePseudoConsoleNative = Void Function(IntPtr hPC);
typedef _ClosePseudoConsoleDart = void Function(int hPC);

final class _PseudoConsoleBindings {
  final _CreatePseudoConsoleDart _create;
  final _ResizePseudoConsoleDart _resize;
  final Pointer<NativeFunction<_ClosePseudoConsoleNative>> closePtr;

  const _PseudoConsoleBindings._(this._create, this._resize, this.closePtr);

  static _PseudoConsoleBindings? tryLoad() {
    final dllPath = ConPtyBundle.resolveConPtyDllPath();
    if (dllPath == null) return null;
    try {
      final lib = DynamicLibrary.open(dllPath);
      return _PseudoConsoleBindings._(
        lib.lookupFunction<
          _CreatePseudoConsoleNative,
          _CreatePseudoConsoleDart
        >('ConptyCreatePseudoConsole'),
        lib.lookupFunction<
          _ResizePseudoConsoleNative,
          _ResizePseudoConsoleDart
        >('ConptyResizePseudoConsole'),
        lib.lookup<NativeFunction<_ClosePseudoConsoleNative>>(
          'ConptyClosePseudoConsole',
        ),
      );
    } on Object {
      return null;
    }
  }

  win32.HPCON? create(
    Arena arena,
    win32.COORD size,
    win32.HANDLE hInput,
    win32.HANDLE hOutput,
    int dwFlags,
  ) {
    final phPC = arena<IntPtr>();
    final hr = win32.HRESULT(_create(size, hInput, hOutput, dwFlags, phPC));
    if (hr.isError) return null;
    final handle = win32.HPCON(phPC.value);
    return handle.isValid ? handle : null;
  }

  void resize(win32.HPCON hPC, win32.COORD size) {
    final hr = win32.HRESULT(_resize(hPC, size));
    if (hr.isError) throw win32.WindowsException(hr);
  }
}

/// The Windows implementation of PtyCore.
///
/// **Architecture & Memory Model:**
/// - **Arena Lifecycle:** Native initialization inside [start] is wrapped in a
///   single `using<PtyCoreWindows>((arena))` scope. This guarantees that if
///   `CreateProcess` fails or we fall back to legacy pipes, all C-strings,
///   startup structs, and temporary pointers are deterministically destroyed
///   upon returning, preventing memory leaks.
/// - **Pointer Casting (hpointer madness):** `package:win32` v5 wraps handles
///   in an extension type over `Pointer`. Therefore, integer handles (like those
///   returned by `CreatePipe` in a struct) must be artificially boxed back into
///   pointers via `win32.HANDLE(Pointer.fromAddress(val))` to satisfy FFI.
final class PtyCoreWindows implements PtyCore, Finalizable {
  /// Internal testing flag to force the legacy fallback.
  static bool forceLegacyForTesting = false;

  static _PseudoConsoleBindings? _cachedConPtyBindings;
  static bool _conPtyProbed = false;

  static _PseudoConsoleBindings? get _activeConPtyBindings {
    if (!_conPtyProbed) {
      _conPtyProbed = true;
      _cachedConPtyBindings = _PseudoConsoleBindings.tryLoad();
    }
    return _cachedConPtyBindings;
  }

  /// Resets a cached negative ConPTY lookup so a newly staged sidecar is
  /// picked up on the next [start] call.
  static void resetConPtyProbeIfUnbound() {
    if (_cachedConPtyBindings == null) {
      _conPtyProbed = false;
    }
  }

  /// Whether [PtyCoreWindows] is backed by the redistributable `conpty.dll` +
  /// `OpenConsole.exe` sidecar rather than inbox `kernel32.dll`.
  static bool get isUsingBundledConPty => _activeConPtyBindings != null;

  static void _closePseudoConsole(
    win32.HPCON hPty,
    Pointer<NativeFunction<_ClosePseudoConsoleNative>>? closePtyPtr,
  ) {
    if (closePtyPtr != null) {
      closePtyPtr.asFunction<_ClosePseudoConsoleDart>()(hPty);
    } else {
      win32.ClosePseudoConsole(hPty);
    }
  }

  /// Formats [executable] and [arguments] into a Windows command-line string
  /// conforming to `CommandLineToArgvW` backslash-and-quote escaping rules.
  static String buildWindowsCommandLine(
    String executable,
    List<String> arguments,
  ) => [
    _quoteWindowsArgument(executable),
    for (final arg in arguments) _quoteWindowsArgument(arg),
  ].join(' ');

  static String _quoteWindowsArgument(String arg) {
    if (arg.isEmpty) return '""';
    if (!arg.contains(' ') && !arg.contains('\t') && !arg.contains('"')) {
      return arg;
    }

    final buffer = StringBuffer('"');
    var backslashes = 0;
    for (final rune in arg.runes) {
      if (rune == 0x5C) {
        backslashes++;
        continue;
      }
      if (rune == 0x22) {
        buffer
          ..write('\\' * (backslashes * 2 + 1))
          ..write('"');
        backslashes = 0;
        continue;
      }
      if (backslashes > 0) {
        buffer.write('\\' * backslashes);
        backslashes = 0;
      }
      buffer.writeCharCode(rune);
    }
    if (backslashes > 0) {
      buffer.write('\\' * (backslashes * 2));
    }
    buffer.write('"');
    return buffer.toString();
  }

  static T _withLock<T>(Pointer<IntPtr> pLock, T Function() action) {
    if (pLock.address == 0) {
      return action();
    }
    _acquireSRWLockExclusive(pLock);
    try {
      return action();
    } finally {
      _releaseSRWLockExclusive(pLock);
    }
  }

  static void _closePseudoConsoleOnce(
    Pointer<IntPtr> pLock,
    Pointer<IntPtr> pHPty,
    Pointer<NativeFunction<_ClosePseudoConsoleNative>>? closePtyPtr,
  ) {
    if (pHPty.address == 0) return;
    _withLock(pLock, () {
      final hPty = pHPty.value;
      if (hPty != 0) {
        pHPty.value = 0;
        _closePseudoConsole(win32.HPCON(hPty), closePtyPtr);
      }
    });
  }

  static void _closeReadSideOnce(
    Pointer<IntPtr> pLock,
    Pointer<IntPtr> pOutputReadSide,
  ) {
    if (pOutputReadSide.address == 0) return;
    _withLock(pLock, () {
      final handle = pOutputReadSide.value;
      if (handle != 0) {
        pOutputReadSide.value = 0;
        win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(handle)));
      }
    });
  }

  static void _closeProcessOnce(
    Pointer<IntPtr> pLock,
    Pointer<IntPtr> pHProcess,
  ) {
    if (pHProcess.address == 0) return;
    _withLock(pLock, () {
      final handle = pHProcess.value;
      if (handle != 0) {
        pHProcess.value = 0;
        win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(handle)));
      }
    });
  }

  static void _closeRawHandle(int address) {
    if (address != 0) {
      win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(address)));
    }
  }

  static Pointer<Utf16>? _buildEnvironmentBlock(
    Arena arena,
    Map<String, String>? environment,
  ) {
    if (environment == null || environment.isEmpty) return null;
    final envMap = {...WinEnv().getEnvironment(), ...environment};
    final buffer = StringBuffer();
    for (final MapEntry(:key, :value) in envMap.entries) {
      buffer
        ..write(key)
        ..write('=')
        ..write(value)
        ..writeCharCode(0);
    }
    buffer.write('\u0000');
    return '$buffer'.toNativeUtf16(allocator: arena);
  }

  static ({win32.HPCON handle, _PseudoConsoleBindings? bindings})?
  _createConPtyHandle(Arena arena, int inputReadAddress, int outWriteAddress) {
    final size = arena<win32.COORD>().ref
      ..X = 80
      ..Y = 25;
    final hInput = win32.HANDLE(Pointer.fromAddress(inputReadAddress));
    final hOutput = win32.HANDLE(Pointer.fromAddress(outWriteAddress));
    final bindings = _activeConPtyBindings;
    if (bindings != null) {
      final ptyHandle = bindings.create(arena, size, hInput, hOutput, 0);
      if (ptyHandle != null) {
        return (handle: ptyHandle, bindings: bindings);
      }
    }
    try {
      final ptyHandle = win32.CreatePseudoConsole(size, hInput, hOutput, 0);
      return ptyHandle.isValid ? (handle: ptyHandle, bindings: null) : null;
    } catch (_) {
      return null;
    }
  }

  static Pointer<win32.STARTUPINFOEX>? _initConPtyStartupInfo(
    Arena arena,
    win32.HPCON hpConPty,
  ) {
    final si = arena<win32.STARTUPINFOEX>();
    si.ref.StartupInfo
      ..cb = sizeOf<win32.STARTUPINFOEX>()
      ..dwFlags = win32.STARTF_USESTDHANDLES
      ..hStdInput = win32.HANDLE(nullptr)
      ..hStdOutput = win32.HANDLE(nullptr)
      ..hStdError = win32.HANDLE(nullptr);

    final bytesRequired = arena<IntPtr>();
    win32.InitializeProcThreadAttributeList(null, 1, bytesRequired);
    final lpAttributeListPtr = arena<Int8>(bytesRequired.value);
    si.ref.lpAttributeList = win32.LPPROC_THREAD_ATTRIBUTE_LIST(
      lpAttributeListPtr,
    );
    win32.InitializeProcThreadAttributeList(
      si.ref.lpAttributeList,
      1,
      bytesRequired,
    );

    final ret = win32.UpdateProcThreadAttribute(
      si.ref.lpAttributeList,
      0,
      win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
      Pointer.fromAddress(hpConPty),
      sizeOf<IntPtr>(),
      nullptr,
      nullptr,
    );
    return ret.value ? si : null;
  }

  static PtyCoreWindows? _tryStartConPty(
    Arena arena,
    win32.PWSTR pwstrCommandLine,
    win32.PCWSTR? pwstrCurrentDirectory,
    Pointer<Utf16>? pEnvironment,
  ) {
    final hInputReadPipe = arena<IntPtr>();
    final hInputWritePipe = arena<IntPtr>();
    final pipe1 = win32.CreatePipe(
      hInputReadPipe.cast<win32.HANDLE>(),
      hInputWritePipe.cast<win32.HANDLE>(),
      nullptr,
      0,
    );

    final hOutReadPipe = arena<IntPtr>();
    final hOutWritePipe = arena<IntPtr>();
    final pipe2 = win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      nullptr,
      0,
    );

    void closeConPtyPipes() {
      _closeRawHandle(hInputReadPipe.value);
      _closeRawHandle(hInputWritePipe.value);
      _closeRawHandle(hOutReadPipe.value);
      _closeRawHandle(hOutWritePipe.value);
    }

    if (pipe1.error != win32.ERROR_SUCCESS ||
        pipe2.error != win32.ERROR_SUCCESS) {
      closeConPtyPipes();
      return null;
    }

    final created = _createConPtyHandle(
      arena,
      hInputReadPipe.value,
      hOutWritePipe.value,
    );
    if (created == null) {
      closeConPtyPipes();
      return null;
    }
    final (handle: hpConPty, :bindings) = created;
    final closePtyPtr = bindings?.closePtr;

    final si = _initConPtyStartupInfo(arena, hpConPty);
    final pi = arena<win32.PROCESS_INFORMATION>();
    final spawned =
        si != null &&
        win32.CreateProcess(
          null,
          pwstrCommandLine,
          null,
          null,
          false,
          win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
          pEnvironment,
          pwstrCurrentDirectory,
          si.cast(),
          pi,
        ).value;

    if (!spawned) {
      _closePseudoConsole(hpConPty, closePtyPtr);
      closeConPtyPipes();
      return null;
    }

    // Check if process crashed immediately (typical for conhost/ConPTY initialization failure in sandbox)
    win32.WaitForSingleObject(pi.ref.hProcess, 30);
    final exitCodePtr = arena<Uint32>();
    win32.GetExitCodeProcess(pi.ref.hProcess, exitCodePtr);
    if (exitCodePtr.value == 3221225794) {
      // 0xC0000142 STATUS_DLL_INIT_FAILED
      win32.CloseHandle(pi.ref.hProcess);
      win32.CloseHandle(pi.ref.hThread);
      _closePseudoConsole(hpConPty, closePtyPtr);
      closeConPtyPipes();
      return null;
    }

    final hProcess = win32.HANDLE(Pointer.fromAddress(pi.ref.hProcess.address));
    win32.CloseHandle(pi.ref.hThread);
    _closeRawHandle(hInputReadPipe.value);
    _closeRawHandle(hOutWritePipe.value);

    return PtyCoreWindows._(
      win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
      win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
      win32.HANDLE(nullptr),
      win32.HANDLE(nullptr),
      hpConPty,
      hProcess,
      conPtyBindings: bindings,
    );
  }

  static PtyCoreWindows _startLegacyPipes(
    Arena arena,
    win32.PWSTR pwstrCommandLine,
    win32.PCWSTR? pwstrCurrentDirectory,
    Pointer<Utf16>? pEnvironment,
  ) {
    final saLegacy = arena<win32.SECURITY_ATTRIBUTES>();
    saLegacy.ref
      ..nLength = sizeOf<win32.SECURITY_ATTRIBUTES>()
      ..lpSecurityDescriptor = nullptr
      ..bInheritHandle = true;

    final hInputReadPipe = arena<IntPtr>();
    final hInputWritePipe = arena<IntPtr>();
    win32.CreatePipe(
      hInputReadPipe.cast<win32.HANDLE>(),
      hInputWritePipe.cast<win32.HANDLE>(),
      saLegacy,
      0,
    );

    final hOutReadPipe = arena<IntPtr>();
    final hOutWritePipe = arena<IntPtr>();
    win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      saLegacy,
      0,
    );

    const handleFlagInherit = 1;
    win32.SetHandleInformation(
      win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
      handleFlagInherit,
      win32.HANDLE_FLAGS(0),
    );
    win32.SetHandleInformation(
      win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
      handleFlagInherit,
      win32.HANDLE_FLAGS(0),
    );

    final siLegacy = arena<win32.STARTUPINFO>();
    siLegacy.ref
      ..cb = sizeOf<win32.STARTUPINFO>()
      ..dwFlags = win32.STARTF_USESTDHANDLES
      ..hStdInput = win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value))
      ..hStdOutput = win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value))
      ..hStdError = win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value));

    final pi = arena<win32.PROCESS_INFORMATION>();
    final piLegacyRet = win32.CreateProcess(
      null,
      pwstrCommandLine,
      null,
      null,
      true,
      win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_NO_WINDOW,
      pEnvironment,
      pwstrCurrentDirectory,
      siLegacy.cast(),
      pi,
    );

    if (!piLegacyRet.value) {
      _closeRawHandle(hInputReadPipe.value);
      _closeRawHandle(hInputWritePipe.value);
      _closeRawHandle(hOutReadPipe.value);
      _closeRawHandle(hOutWritePipe.value);
      return PtyCoreWindows._failed();
    }

    final hProcess = win32.HANDLE(Pointer.fromAddress(pi.ref.hProcess.address));
    win32.CloseHandle(pi.ref.hThread);
    _closeRawHandle(hInputReadPipe.value);
    _closeRawHandle(hOutWritePipe.value);

    return PtyCoreWindows._(
      win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
      win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
      win32.HANDLE(nullptr),
      win32.HANDLE(nullptr),
      null,
      hProcess,
    );
  }

  factory PtyCoreWindows.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool blocking = false,
  }) {
    return using<PtyCoreWindows>((arena) {
      final pwstrCommandLine = buildWindowsCommandLine(
        executable,
        arguments,
      ).toPwstr(allocator: arena);
      final pwstrCurrentDirectory = workingDirectory?.toPcwstr(
        allocator: arena,
      );
      final pEnvironment = _buildEnvironmentBlock(arena, environment);

      if (!forceLegacyForTesting) {
        final conPty = _tryStartConPty(
          arena,
          pwstrCommandLine,
          pwstrCurrentDirectory,
          pEnvironment,
        );
        if (conPty != null) return conPty;
      }

      return _startLegacyPipes(
        arena,
        pwstrCommandLine,
        pwstrCurrentDirectory,
        pEnvironment,
      );
    });
  }

  PtyCoreWindows._(
    this._inputWriteSide,
    win32.HANDLE outputReadSide,
    this._inputReadSide,
    this._outputWriteSide,
    win32.HPCON? hPty,
    win32.HANDLE hProcess, {
    _PseudoConsoleBindings? conPtyBindings,
  }) : _conPtyBindings = conPtyBindings,
       _failed = false {
    _writeBuffer = calloc<Uint8>(_bufferSize + 1);
    _pWritten = calloc<Uint32>();

    final readBuffer = calloc<Uint8>(_bufferSize + 1);
    final pReadlen = calloc<Uint32>();

    final pLock = calloc<IntPtr>();
    final pHPty = calloc<IntPtr>()..value = hPty ?? 0;
    final pOutputReadSide = calloc<IntPtr>()..value = outputReadSide.address;
    final pHProcess = calloc<IntPtr>()..value = hProcess.address;
    _pLock = pLock;
    _pHPty = pHPty;
    _pOutputReadSide = pOutputReadSide;
    _pHProcess = pHProcess;

    _worker = PtyCoreWindowsWorker(
      pLock: pLock,
      pOutputReadSide: pOutputReadSide,
      pHProcess: pHProcess,
      pHPty: pHPty,
      closePtyPtr: conPtyBindings?.closePtr,
      buffer: readBuffer,
      pReadlen: pReadlen,
      bufferSize: _bufferSize,
      failed: false,
    );

    _finalizer.attach(this, _writeBuffer.cast(), detach: _writeDetachToken);
    _finalizer.attach(this, _pWritten.cast(), detach: _writeDetachToken);
    _finalizer.attach(this, _pLock.cast(), detach: this);
    _finalizer.attach(this, _pHPty.cast(), detach: this);
    _finalizer.attach(this, _pOutputReadSide.cast(), detach: this);
    _finalizer.attach(this, _pHProcess.cast(), detach: this);

    _attachHandleFinalizer(_inputWriteSide);
    _attachHandleFinalizer(_inputReadSide);
    _attachHandleFinalizer(_outputWriteSide);
  }

  void _attachHandleFinalizer(win32.HANDLE handle) {
    if (handle.address != 0) {
      _closeHandleFinalizer.attach(
        this,
        Pointer.fromAddress(handle.address),
        detach: this,
      );
    }
  }

  PtyCoreWindows._failed()
    : _inputWriteSide = win32.HANDLE(nullptr),
      _inputReadSide = win32.HANDLE(nullptr),
      _outputWriteSide = win32.HANDLE(nullptr),
      _conPtyBindings = null,
      _failed = true {
    _writeBuffer = nullptr;
    _pWritten = nullptr;
    _pLock = nullptr;
    _pHPty = nullptr;
    _pOutputReadSide = nullptr;
    _pHProcess = nullptr;
    _worker = PtyCoreWindowsWorker(
      pLock: nullptr,
      pOutputReadSide: null,
      pHProcess: null,
      pHPty: null,
      closePtyPtr: null,
      buffer: nullptr,
      pReadlen: nullptr,
      bufferSize: 0,
      failed: true,
    );
  }

  win32.HANDLE _inputWriteSide;
  win32.HANDLE _inputReadSide;
  win32.HANDLE _outputWriteSide;
  final _PseudoConsoleBindings? _conPtyBindings;
  final bool _failed;
  final Object _writeDetachToken = Object();

  late final Pointer<IntPtr> _pLock;
  late final Pointer<IntPtr> _pHPty;
  late final Pointer<IntPtr> _pOutputReadSide;
  late final Pointer<IntPtr> _pHProcess;

  static const _bufferSize = 4096;
  late Pointer<Uint8> _writeBuffer;
  late Pointer<Uint32> _pWritten;

  late final PtyCoreWindowsWorker _worker;

  @override
  PtyCoreWindowsWorker get worker => _worker;

  static final _finalizer = NativeFinalizer(calloc.nativeFree);

  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _acquireSRWLockExclusive = _kernel32
      .lookupFunction<
        Void Function(Pointer<IntPtr>),
        void Function(Pointer<IntPtr>)
      >('AcquireSRWLockExclusive');

  static final _releaseSRWLockExclusive = _kernel32
      .lookupFunction<
        Void Function(Pointer<IntPtr>),
        void Function(Pointer<IntPtr>)
      >('ReleaseSRWLockExclusive');

  static final _closeHandleFinalizer = NativeFinalizer(
    _kernel32.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'CloseHandle',
    ),
  );

  @override
  Uint8List? read() => _worker.read();

  @override
  void onReaderClosed() {}

  @override
  int? exitCodeNonBlocking() {
    if (_failed) return 1;
    if (_pHProcess.address == 0) return null;
    return using((arena) {
      final exitCodePtr = arena<Uint32>();
      return _withLock(_pLock, () {
        final hProcAddress = _pHProcess.value;
        if (hProcAddress == 0) return null;
        final hProc = win32.HANDLE(Pointer.fromAddress(hProcAddress));
        final ret = win32.GetExitCodeProcess(hProc, exitCodePtr);
        final exitCode = exitCodePtr.value;

        const stillActive = 259;
        if (!ret.value || exitCode == stillActive) {
          return null;
        }

        _pHProcess.value = 0;
        win32.CloseHandle(hProc);
        return exitCode;
      });
    });
  }

  @override
  int exitCodeBlocking() => _worker.exitCodeBlocking();

  bool _killed = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_failed || _killed) return true;
    _killed = true;

    if (_writeBuffer != nullptr) {
      calloc.free(_writeBuffer);
      _writeBuffer = nullptr;
    }
    if (_pWritten != nullptr) {
      calloc.free(_pWritten);
      _pWritten = nullptr;
    }
    _finalizer.detach(_writeDetachToken);
    _closeHandleFinalizer.detach(this);

    final ret = _withLock(_pLock, () {
      final hProcAddress = _pHProcess.address != 0 ? _pHProcess.value : 0;
      return hProcAddress == 0 ||
          win32.TerminateProcess(
            win32.HANDLE(Pointer.fromAddress(hProcAddress)),
            0,
          ).value;
    });
    _closePseudoConsoleOnce(_pLock, _pHPty, _conPtyBindings?.closePtr);

    _closeRawHandle(_inputReadSide.address);
    _inputReadSide = win32.HANDLE(nullptr);
    _closeRawHandle(_outputWriteSide.address);
    _outputWriteSide = win32.HANDLE(nullptr);
    _closeRawHandle(_inputWriteSide.address);
    _inputWriteSide = win32.HANDLE(nullptr);
    _closeReadSideOnce(_pLock, _pOutputReadSide);
    return ret;
  }

  @override
  void resize(int width, int height) {
    if (_failed || _killed || _pHPty == nullptr) return;
    final bindings = _conPtyBindings;
    using((arena) {
      final size = arena<win32.COORD>();
      size.ref.X = width;
      size.ref.Y = height;
      _withLock(_pLock, () {
        final hPty = _pHPty.value;
        if (hPty == 0) return;
        try {
          if (bindings != null) {
            bindings.resize(win32.HPCON(hPty), size.ref);
          } else {
            win32.ResizePseudoConsole(win32.HPCON(hPty), size.ref);
          }
        } on win32.WindowsException {
          // Child exited naturally before or during resize.
        }
      });
    });
  }

  @override
  void write(List<int> data) {
    if (_failed || _killed || _writeBuffer == nullptr) return;
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final chunkLen = remaining > _bufferSize ? _bufferSize : remaining;
      _writeBuffer.asTypedList(chunkLen).setRange(0, chunkLen, data, offset);
      win32.WriteFile(
        _inputWriteSide,
        _writeBuffer,
        chunkLen,
        _pWritten,
        nullptr,
      );
      offset += chunkLen;
    }
  }
}

final class PtyCoreWindowsWorker implements PtyCoreWorker {
  final Pointer<IntPtr> pLock;
  final Pointer<IntPtr>? pHProcess;
  final Pointer<IntPtr>? pOutputReadSide;
  final Pointer<IntPtr>? pHPty;
  final Pointer<NativeFunction<Void Function(IntPtr)>>? closePtyPtr;
  final Pointer<Uint8> buffer;
  final Pointer<Uint32> pReadlen;
  final int bufferSize;
  final bool failed;

  PtyCoreWindowsWorker({
    required this.pLock,
    required this.pOutputReadSide,
    required this.pHProcess,
    required this.pHPty,
    required this.closePtyPtr,
    required this.buffer,
    required this.pReadlen,
    required this.bufferSize,
    required this.failed,
  });

  @override
  Uint8List? read() {
    if (failed) return null;
    final pOutput = pOutputReadSide;
    if (pOutput == null || pOutput.address == 0) return null;

    final handleAddress = PtyCoreWindows._withLock(pLock, () => pOutput.value);
    if (handleAddress == 0) return null;

    final ret = win32.ReadFile(
      win32.HANDLE(Pointer.fromAddress(handleAddress)),
      buffer,
      bufferSize,
      pReadlen,
      nullptr,
    );

    final readlen = pReadlen.value;
    if ((ret.value || ret.error == win32.ERROR_MORE_DATA) && readlen > 0) {
      return Uint8List.fromList(buffer.asTypedList(readlen));
    }
    return null;
  }

  @override
  int exitCodeBlocking() {
    if (failed) return 1;
    final pProc = pHProcess;
    if (pProc == null || pProc.address == 0) return 1;
    final handleAddress = PtyCoreWindows._withLock(pLock, () => pProc.value);
    if (handleAddress == 0) return 1;
    final hProc = win32.HANDLE(Pointer.fromAddress(handleAddress));

    const infinite = 0xFFFFFFFF;
    win32.WaitForSingleObject(hProc, infinite);

    final exitCode = using((arena) {
      final exitCodePtr = arena<Uint32>();
      return PtyCoreWindows._withLock(pLock, () {
        final currentAddress = pProc.value;
        if (currentAddress == 0) return 0;
        final currentProc = win32.HANDLE(Pointer.fromAddress(currentAddress));
        win32.GetExitCodeProcess(currentProc, exitCodePtr);
        pProc.value = 0;
        win32.CloseHandle(currentProc);
        return exitCodePtr.value;
      });
    });

    // Close the pseudoconsole so ConPTY flushes remaining output and
    // closes the output write pipe. The reader isolate will then read
    // the flushed data and hit ERROR_BROKEN_PIPE (EOF) naturally.
    final pHPtyPtr = pHPty;
    if (pHPtyPtr != null) {
      PtyCoreWindows._closePseudoConsoleOnce(pLock, pHPtyPtr, closePtyPtr);
    }

    return exitCode;
  }

  @override
  void free() {
    if (buffer != nullptr) calloc.free(buffer);
    if (pReadlen != nullptr) calloc.free(pReadlen);

    final pOutput = pOutputReadSide;
    if (pOutput != null) {
      PtyCoreWindows._closeReadSideOnce(pLock, pOutput);
    }

    final pPty = pHPty;
    if (pPty != null) {
      PtyCoreWindows._closePseudoConsoleOnce(pLock, pPty, closePtyPtr);
    }

    final pProc = pHProcess;
    if (pProc != null) {
      PtyCoreWindows._closeProcessOnce(pLock, pProc);
    }
  }
}

typedef GetEnvironmentStringsNative = Pointer<Utf16> Function();
typedef GetEnvironmentStringsDart = Pointer<Utf16> Function();
typedef FreeEnvironmentStringsNative =
    Int32 Function(Pointer<Utf16> lpszEnvironmentBlock);
typedef FreeEnvironmentStringsDart =
    int Function(Pointer<Utf16> lpszEnvironmentBlock);

final class WinEnv {
  static final kernel32 = DynamicLibrary.open('kernel32.dll');

  static final getEnvironmentStringsW = kernel32
      .lookupFunction<GetEnvironmentStringsNative, GetEnvironmentStringsDart>(
        'GetEnvironmentStringsW',
      );

  static final freeEnvironmentStringsW = kernel32
      .lookupFunction<FreeEnvironmentStringsNative, FreeEnvironmentStringsDart>(
        'FreeEnvironmentStringsW',
      );

  Map<String, String> getEnvironment() {
    final wstrings = getEnvironmentStringsW();

    try {
      final strings = win32.PWSTR(wstrings).toDartStringList(32 * 1024);
      var map = <String, String>{};
      for (var string in strings) {
        if (string.startsWith('=')) continue;
        final int separatorIndex = string.indexOf(
          '=',
          1,
        ); // Start at 1 to skip leading '='
        if (separatorIndex != -1) {
          final k = string.substring(0, separatorIndex);
          final v = string.substring(separatorIndex + 1);
          map[k] = v;
        }
      }

      return map;
    } finally {
      freeEnvironmentStringsW(wstrings);
    }
  }
}
