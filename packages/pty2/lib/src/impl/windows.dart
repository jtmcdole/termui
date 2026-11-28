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

  static const _pipeBufferSize = 65536;
  static int _pipeSequence = 0;

  static void _signalWriteStop(Pointer<IntPtr> pStopEvent) {
    if (pStopEvent.address == 0) return;
    final handle = pStopEvent.value;
    if (handle != 0) {
      win32.SetEvent(win32.HANDLE(Pointer.fromAddress(handle)));
    }
  }

  static void _closeInputWriteOnce(
    Pointer<IntPtr> pLock,
    Pointer<IntPtr> pInputWriteSide,
  ) {
    if (pInputWriteSide.address == 0) return;
    _withLock(pLock, () {
      final handle = pInputWriteSide.value;
      if (handle != 0) {
        pInputWriteSide.value = 0;
        win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(handle)));
      }
    });
  }

  /// Creates an input pipe whose write end supports overlapped I/O (allowing
  /// race-free stop-event cancellation via `WaitForMultipleObjects`) while the
  /// read end remains synchronous as required by ConPTY and legacy child stdin.
  static ({int readHandle, int writeHandle})? _createOverlappedInputPipe(
    Arena arena, {
    Pointer<win32.SECURITY_ATTRIBUTES>? readSecurityAttributes,
  }) {
    final seq = ++_pipeSequence;
    final name =
        r'\\.\pipe\pty2_in_'
        '${pid}_${seq}_${DateTime.now().microsecondsSinceEpoch}';
    final lpName = name.toPcwstr(allocator: arena);
    final hWrite = win32.CreateNamedPipe(
      lpName,
      win32.FILE_FLAGS_AND_ATTRIBUTES(
        win32.PIPE_ACCESS_OUTBOUND |
            win32.FILE_FLAG_OVERLAPPED |
            win32.FILE_FLAG_FIRST_PIPE_INSTANCE,
      ),
      win32.NAMED_PIPE_MODE(win32.PIPE_TYPE_BYTE | win32.PIPE_WAIT),
      1,
      _pipeBufferSize,
      _pipeBufferSize,
      0,
      null,
    );
    if (!hWrite.isValid) return null;

    final hReadResult = win32.CreateFile(
      lpName,
      win32.GENERIC_READ,
      win32.FILE_SHARE_MODE(0),
      readSecurityAttributes,
      win32.FILE_CREATION_DISPOSITION(win32.OPEN_EXISTING),
      win32.FILE_FLAGS_AND_ATTRIBUTES(win32.FILE_ATTRIBUTE_NORMAL),
      null,
    );
    if (!hReadResult.value.isValid) {
      win32.CloseHandle(hWrite);
      return null;
    }
    return (readHandle: hReadResult.value.address, writeHandle: hWrite.address);
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
    final inputPipe = _createOverlappedInputPipe(arena);
    if (inputPipe == null) return null;
    final hInputReadPipe = inputPipe.readHandle;
    final hInputWritePipe = inputPipe.writeHandle;

    final hOutReadPipe = arena<IntPtr>();
    final hOutWritePipe = arena<IntPtr>();
    final pipe2 = win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      nullptr,
      _pipeBufferSize,
    );

    void closeConPtyPipes() {
      _closeRawHandle(hInputReadPipe);
      _closeRawHandle(hInputWritePipe);
      _closeRawHandle(hOutReadPipe.value);
      _closeRawHandle(hOutWritePipe.value);
    }

    if (!pipe2.value) {
      closeConPtyPipes();
      return null;
    }

    final created = _createConPtyHandle(
      arena,
      hInputReadPipe,
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
    _closeRawHandle(hInputReadPipe);
    _closeRawHandle(hOutWritePipe.value);

    return PtyCoreWindows._(
      win32.HANDLE(Pointer.fromAddress(hInputWritePipe)),
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

    final inputPipe = _createOverlappedInputPipe(
      arena,
      readSecurityAttributes: saLegacy,
    );
    if (inputPipe == null) {
      return PtyCoreWindows._failed();
    }
    final hInputReadPipe = inputPipe.readHandle;
    final hInputWritePipe = inputPipe.writeHandle;

    final hOutReadPipe = arena<IntPtr>();
    final hOutWritePipe = arena<IntPtr>();
    final outPipeOk = win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      saLegacy,
      _pipeBufferSize,
    );
    if (!outPipeOk.value) {
      _closeRawHandle(hInputReadPipe);
      _closeRawHandle(hInputWritePipe);
      return PtyCoreWindows._failed();
    }

    const handleFlagInherit = 1;
    win32.SetHandleInformation(
      win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
      handleFlagInherit,
      win32.HANDLE_FLAGS(0),
    );

    final siLegacy = arena<win32.STARTUPINFO>();
    siLegacy.ref
      ..cb = sizeOf<win32.STARTUPINFO>()
      ..dwFlags = win32.STARTF_USESTDHANDLES
      ..hStdInput = win32.HANDLE(Pointer.fromAddress(hInputReadPipe))
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
      _closeRawHandle(hInputReadPipe);
      _closeRawHandle(hInputWritePipe);
      _closeRawHandle(hOutReadPipe.value);
      _closeRawHandle(hOutWritePipe.value);
      return PtyCoreWindows._failed();
    }

    final hProcess = win32.HANDLE(Pointer.fromAddress(pi.ref.hProcess.address));
    win32.CloseHandle(pi.ref.hThread);
    _closeRawHandle(hInputReadPipe);
    _closeRawHandle(hOutWritePipe.value);

    return PtyCoreWindows._(
      win32.HANDLE(Pointer.fromAddress(hInputWritePipe)),
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
    win32.HANDLE inputWriteSide,
    win32.HANDLE outputReadSide,
    this._inputReadSide,
    this._outputWriteSide,
    win32.HPCON? hPty,
    win32.HANDLE hProcess, {
    _PseudoConsoleBindings? conPtyBindings,
  }) : _conPtyBindings = conPtyBindings,
       _failed = false {
    final readBuffer = calloc<Uint8>(_bufferSize + 1);
    final pReadlen = calloc<Uint32>();

    final pLock = calloc<IntPtr>();
    final pHPty = calloc<IntPtr>()..value = hPty ?? 0;
    final pOutputReadSide = calloc<IntPtr>()..value = outputReadSide.address;
    final pInputWriteSide = calloc<IntPtr>()..value = inputWriteSide.address;
    final hStopEvent = win32.CreateEvent(null, true, false, null).value;
    final pStopEvent = calloc<IntPtr>()
      ..value = hStopEvent.isValid ? hStopEvent.address : 0;
    final pHProcess = calloc<IntPtr>()..value = hProcess.address;
    _pLock = pLock;
    _pHPty = pHPty;
    _pOutputReadSide = pOutputReadSide;
    _pInputWriteSide = pInputWriteSide;
    _pStopEvent = pStopEvent;
    _pHProcess = pHProcess;

    _worker = PtyCoreWindowsWorker(
      pLock: pLock,
      pOutputReadSide: pOutputReadSide,
      pHProcess: pHProcess,
      pHPty: pHPty,
      pStopEvent: pStopEvent,
      closePtyPtr: conPtyBindings?.closePtr,
      buffer: readBuffer,
      pReadlen: pReadlen,
      bufferSize: _bufferSize,
      failed: false,
    );

    _finalizer.attach(this, _pLock.cast(), detach: this);
    _finalizer.attach(this, _pHPty.cast(), detach: this);
    _finalizer.attach(this, _pOutputReadSide.cast(), detach: this);
    _finalizer.attach(this, _pInputWriteSide.cast(), detach: this);
    _finalizer.attach(this, _pStopEvent.cast(), detach: this);
    _finalizer.attach(this, _pHProcess.cast(), detach: this);

    _attachHandleFinalizer(inputWriteSide, detach: _inputWriteDetachToken);
    if (hStopEvent.isValid) {
      _attachHandleFinalizer(hStopEvent, detach: _stopEventDetachToken);
    }
    _attachHandleFinalizer(_inputReadSide);
    _attachHandleFinalizer(_outputWriteSide);
  }

  void _attachHandleFinalizer(win32.HANDLE handle, {Object? detach}) {
    if (handle.address != 0) {
      _closeHandleFinalizer.attach(
        this,
        Pointer.fromAddress(handle.address),
        detach: detach ?? this,
      );
    }
  }

  PtyCoreWindows._failed()
    : _inputReadSide = win32.HANDLE(nullptr),
      _outputWriteSide = win32.HANDLE(nullptr),
      _conPtyBindings = null,
      _failed = true {
    _pLock = nullptr;
    _pHPty = nullptr;
    _pOutputReadSide = nullptr;
    _pInputWriteSide = nullptr;
    _pStopEvent = nullptr;
    _pHProcess = nullptr;
    _worker = PtyCoreWindowsWorker(
      pLock: nullptr,
      pOutputReadSide: null,
      pHProcess: null,
      pHPty: null,
      pStopEvent: null,
      closePtyPtr: null,
      buffer: nullptr,
      pReadlen: nullptr,
      bufferSize: 0,
      failed: true,
    );
  }

  win32.HANDLE _inputReadSide;
  win32.HANDLE _outputWriteSide;
  final _PseudoConsoleBindings? _conPtyBindings;
  final bool _failed;
  final Object _inputWriteDetachToken = Object();
  final Object _stopEventDetachToken = Object();
  bool _writerTaken = false;

  late final Pointer<IntPtr> _pLock;
  late final Pointer<IntPtr> _pHPty;
  late final Pointer<IntPtr> _pOutputReadSide;
  late final Pointer<IntPtr> _pInputWriteSide;
  late final Pointer<IntPtr> _pStopEvent;
  late final Pointer<IntPtr> _pHProcess;

  static const _bufferSize = 4096;

  late final PtyCoreWindowsWorker _worker;

  @override
  PtyCoreWindowsWorker get worker => _worker;

  @override
  PtyCoreWriter takeWriter() {
    if (_writerTaken) {
      throw StateError('PTY writer ownership has already been transferred.');
    }
    _writerTaken = true;
    _closeHandleFinalizer.detach(_inputWriteDetachToken);
    if (_failed || _killed) {
      _closeInputWriteOnce(_pLock, _pInputWriteSide);
      return const ClosedPtyCoreWriter();
    }
    return _PtyCoreWindowsWriter(
      pLock: _pLock,
      pInputWriteSide: _pInputWriteSide,
      pStopEvent: _pStopEvent,
    );
  }

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
  void onReaderClosed() {
    if (!_failed) {
      _signalWriteStop(_pStopEvent);
    }
  }

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

    _closeHandleFinalizer.detach(this);
    _signalWriteStop(_pStopEvent);

    final ret = _withLock(_pLock, () {
      final hProcAddress = _pHProcess.address != 0 ? _pHProcess.value : 0;
      return hProcAddress == 0 ||
          win32.TerminateProcess(
            win32.HANDLE(Pointer.fromAddress(hProcAddress)),
            0,
          ).value;
    });
    _closePseudoConsoleOnce(_pLock, _pHPty, _conPtyBindings?.closePtr);
    if (!_writerTaken) {
      _closeHandleFinalizer.detach(_inputWriteDetachToken);
      _closeInputWriteOnce(_pLock, _pInputWriteSide);
    }

    _closeRawHandle(_inputReadSide.address);
    _inputReadSide = win32.HANDLE(nullptr);
    _closeRawHandle(_outputWriteSide.address);
    _outputWriteSide = win32.HANDLE(nullptr);
    _closeReadSideOnce(_pLock, _pOutputReadSide);
    return ret;
  }

  @override
  void resize(
    int width,
    int height, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
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
    if (_writerTaken) {
      throw StateError(
        'PTY writer ownership has already been transferred via takeWriter().',
      );
    }
    if (_failed || _killed || data.isEmpty) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final handleAddress = _withLock(_pLock, () => _pInputWriteSide.value);
    final stopEventAddress = _pStopEvent.address != 0 ? _pStopEvent.value : 0;
    if (handleAddress == 0 || stopEventAddress == 0) return;

    final ioEvent = win32.CreateEvent(null, true, false, null).value;
    if (!ioEvent.isValid) return;
    try {
      using((arena) {
        final buf = arena<Uint8>(_PtyCoreWindowsWriter._writeChunkSize);
        final pWritten = arena<Uint32>();
        final pOverlapped = arena<win32.OVERLAPPED>();
        final pWaitHandles = arena<Pointer>(2);
        pWaitHandles[0] = Pointer.fromAddress(stopEventAddress);
        pWaitHandles[1] = Pointer.fromAddress(ioEvent.address);
        _PtyCoreWindowsWriter._writeOverlappedLoop(
          bytes: bytes,
          handle: win32.HANDLE(Pointer.fromAddress(handleAddress)),
          stopEvent: win32.HANDLE(Pointer.fromAddress(stopEventAddress)),
          ioEvent: ioEvent,
          buf: buf,
          pWritten: pWritten,
          pOverlapped: pOverlapped,
          pWaitHandles: pWaitHandles,
        );
      });
    } finally {
      win32.CloseHandle(ioEvent);
    }
  }
}

final class _PtyCoreWindowsWriter implements PtyCoreWriter {
  static const _writeChunkSize = 16384;
  static const _infinite = 0xFFFFFFFF;

  final Pointer<IntPtr> _pLock;
  final Pointer<IntPtr> _pInputWriteSide;
  final Pointer<IntPtr> _pStopEvent;

  bool _freed = false;
  Pointer<Uint8>? _writeBuffer;
  Pointer<Uint32>? _pWritten;
  Pointer<win32.OVERLAPPED>? _pOverlapped;
  Pointer<Pointer>? _pWaitHandles;
  int _ioEventAddress = 0;

  _PtyCoreWindowsWriter({
    required Pointer<IntPtr> pLock,
    required Pointer<IntPtr> pInputWriteSide,
    required Pointer<IntPtr> pStopEvent,
  }) : _pLock = pLock,
       _pInputWriteSide = pInputWriteSide,
       _pStopEvent = pStopEvent;

  int _resolveStopEventAddress() =>
      _pStopEvent.address != 0 ? _pStopEvent.value : 0;

  bool _isStopSignaled(int stopEventAddress) {
    if (stopEventAddress == 0) return true;
    final wait = win32.WaitForSingleObject(
      win32.HANDLE(Pointer.fromAddress(stopEventAddress)),
      0,
    );
    return wait.value == win32.WAIT_OBJECT_0;
  }

  int _resolveActiveHandle() {
    if (_freed || _pInputWriteSide.address == 0) return 0;
    final stopEventAddress = _resolveStopEventAddress();
    if (_isStopSignaled(stopEventAddress)) return 0;
    return PtyCoreWindows._withLock(_pLock, () => _pInputWriteSide.value);
  }

  static int _writeSingleChunkOverlapped({
    required win32.HANDLE handle,
    required win32.HANDLE ioEvent,
    required Pointer<Uint8> buf,
    required int chunkLen,
    required Pointer<Uint32> pWritten,
    required Pointer<win32.OVERLAPPED> pOverlapped,
    required Pointer<Pointer> pWaitHandles,
  }) {
    win32.ResetEvent(ioEvent);
    pOverlapped.ref
      ..Internal = 0
      ..InternalHigh = 0
      ..Offset = 0
      ..OffsetHigh = 0
      ..hEvent = ioEvent;
    pWritten.value = 0;

    final ret = win32.WriteFile(handle, buf, chunkLen, pWritten, pOverlapped);
    if (ret.value) return pWritten.value;
    if (ret.error != win32.ERROR_IO_PENDING) return 0;

    final wait = win32.WaitForMultipleObjects(
      2,
      pWaitHandles,
      false,
      _infinite,
    );
    if (wait.value == win32.WAIT_EVENT(win32.WAIT_OBJECT_0 + 1)) {
      final done = win32.GetOverlappedResult(
        handle,
        pOverlapped,
        pWritten,
        false,
      );
      return done.value ? pWritten.value : 0;
    }

    // Stop event signaled (WAIT_OBJECT_0) or wait failed: cancel the pending
    // IRP and wait for kernel completion before reusing or freeing buffers.
    win32.CancelIoEx(handle, pOverlapped);
    win32.GetOverlappedResult(handle, pOverlapped, pWritten, true);
    return 0;
  }

  static PtyWriteStatus _writeOverlappedLoop({
    required Uint8List bytes,
    required win32.HANDLE handle,
    required win32.HANDLE stopEvent,
    required win32.HANDLE ioEvent,
    required Pointer<Uint8> buf,
    required Pointer<Uint32> pWritten,
    required Pointer<win32.OVERLAPPED> pOverlapped,
    required Pointer<Pointer> pWaitHandles,
  }) {
    var offset = 0;
    while (offset < bytes.length) {
      if (win32.WaitForSingleObject(stopEvent, 0).value ==
          win32.WAIT_OBJECT_0) {
        return PtyWriteStatus.closed;
      }
      final remaining = bytes.length - offset;
      final chunkLen = remaining > _writeChunkSize
          ? _writeChunkSize
          : remaining;
      buf.asTypedList(chunkLen).setRange(0, chunkLen, bytes, offset);

      final written = _writeSingleChunkOverlapped(
        handle: handle,
        ioEvent: ioEvent,
        buf: buf,
        chunkLen: chunkLen,
        pWritten: pWritten,
        pOverlapped: pOverlapped,
        pWaitHandles: pWaitHandles,
      );
      if (written == 0) return PtyWriteStatus.closed;
      offset += written;
    }
    return PtyWriteStatus.written;
  }

  bool _ensureBuffersAllocated(int stopEventAddress) {
    if (_ioEventAddress == 0) {
      final ev = win32.CreateEvent(null, true, false, null).value;
      if (!ev.isValid) return false;
      _ioEventAddress = ev.address;
    }
    _writeBuffer ??= calloc<Uint8>(_writeChunkSize);
    _pWritten ??= calloc<Uint32>();
    _pOverlapped ??= calloc<win32.OVERLAPPED>();
    final handles = _pWaitHandles ??= calloc<Pointer>(2);
    handles[0] = Pointer.fromAddress(stopEventAddress);
    handles[1] = Pointer.fromAddress(_ioEventAddress);
    return true;
  }

  @override
  PtyWriteStatus write(Uint8List data) {
    final handleAddress = _resolveActiveHandle();
    if (handleAddress == 0) return PtyWriteStatus.closed;
    if (data.isEmpty) return PtyWriteStatus.written;

    final stopEventAddress = _resolveStopEventAddress();
    if (!_ensureBuffersAllocated(stopEventAddress)) {
      return PtyWriteStatus.closed;
    }
    return _writeOverlappedLoop(
      bytes: data,
      handle: win32.HANDLE(Pointer.fromAddress(handleAddress)),
      stopEvent: win32.HANDLE(Pointer.fromAddress(stopEventAddress)),
      ioEvent: win32.HANDLE(Pointer.fromAddress(_ioEventAddress)),
      buf: _writeBuffer!,
      pWritten: _pWritten!,
      pOverlapped: _pOverlapped!,
      pWaitHandles: _pWaitHandles!,
    );
  }

  @override
  void free() {
    if (_freed) return;
    _freed = true;
    if (_writeBuffer != null && _writeBuffer != nullptr) {
      calloc.free(_writeBuffer!);
      _writeBuffer = null;
    }
    if (_pWritten != null && _pWritten != nullptr) {
      calloc.free(_pWritten!);
      _pWritten = null;
    }
    if (_pOverlapped != null && _pOverlapped != nullptr) {
      calloc.free(_pOverlapped!);
      _pOverlapped = null;
    }
    if (_pWaitHandles != null && _pWaitHandles != nullptr) {
      calloc.free(_pWaitHandles!);
      _pWaitHandles = null;
    }
    if (_ioEventAddress != 0) {
      win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(_ioEventAddress)));
      _ioEventAddress = 0;
    }
    PtyCoreWindows._closeInputWriteOnce(_pLock, _pInputWriteSide);
  }
}

final class PtyCoreWindowsWorker implements PtyCoreWorker {
  final Pointer<IntPtr> pLock;
  final Pointer<IntPtr>? pHProcess;
  final Pointer<IntPtr>? pOutputReadSide;
  final Pointer<IntPtr>? pHPty;
  final Pointer<IntPtr>? pStopEvent;
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
    required this.pStopEvent,
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

    // Signal the stop event so any blocked overlapped writer wakes up even
    // when a legacy-pipe grandchild still holds the stdin read end open.
    final pStop = pStopEvent;
    if (pStop != null) {
      PtyCoreWindows._signalWriteStop(pStop);
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
