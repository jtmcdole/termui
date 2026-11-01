// coverage:ignore-file
// ignore_for_file: public_member_api_docs, constant_identifier_names, camel_case_types, non_constant_identifier_names, lines_longer_than_80_chars

// cspell:words tcgetattr BRKINT ICRNL INPCK ISTRIP IXON lflag CSIZE PARENB
// cspell:words fildes termios ospeed ispeed tcflag ncss nccs vtime vmin cflag
// cspell:words icanon isig iexten tcsanow tcsetattr FILENO iflag oflag OPOST

import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:termui/src/terminal/reusable_input_stream.dart';

import 'terminal.dart';

class UnixTerminal implements Terminal {
  UnixTerminal({int fd = _STDIN_FILENO}) : _fd = fd {
    _lib = Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.dylib')
        : DynamicLibrary.open('libc.so.6');

    _tcgetattr = _lib.lookupFunction<TCGetAttrNative, TCGetAttrDart>(
      'tcgetattr',
    );
    _tcsetattr = _lib.lookupFunction<TCSetAttrNative, TCSetAttrDart>(
      'tcsetattr',
    );

    _captureOrigTermIOS();
  }

  final int _fd;
  late final DynamicLibrary _lib;
  Pointer<Void> _origTermIOSPointer = nullptr;
  late final TCGetAttrDart _tcgetattr;
  late final TCSetAttrDart _tcsetattr;

  void _captureOrigTermIOS() {
    if (_origTermIOSPointer != nullptr) return;
    if (Platform.isMacOS) {
      final ptr = calloc<DarwinTermIOS>();
      _tcgetattr(_fd, ptr.cast());
      _origTermIOSPointer = ptr.cast();
    } else {
      final ptr = calloc<LinuxTermIOS>();
      _tcgetattr(_fd, ptr.cast());
      _origTermIOSPointer = ptr.cast();
    }
  }

  @override
  Point<int> getScreenBufferSize() {
    try {
      if (stdout.hasTerminal) {
        return Point(stdout.terminalColumns, stdout.terminalLines);
      }
      if (stderr.hasTerminal) {
        return Point(stderr.terminalColumns, stderr.terminalLines);
      }
    } catch (_) {
      // Ignore
    }
    return const Point(-1, -1);
  }

  @override
  void enableRawMode() {
    if (_origTermIOSPointer == nullptr) {
      _captureOrigTermIOS();
    }

    if (Platform.isMacOS) {
      final origTermIOS = _origTermIOSPointer.cast<DarwinTermIOS>().ref;
      final newTermIOSPointer = calloc<DarwinTermIOS>();
      configureDarwinRawTermIOS(origTermIOS, newTermIOSPointer.ref);
      _tcsetattr(_fd, _TCSANOW, newTermIOSPointer.cast());
      calloc.free(newTermIOSPointer);
    } else {
      final origTermIOS = _origTermIOSPointer.cast<LinuxTermIOS>().ref;
      final newTermIOSPointer = calloc<LinuxTermIOS>();
      configureLinuxRawTermIOS(origTermIOS, newTermIOSPointer.ref);
      _tcsetattr(_fd, _TCSANOW, newTermIOSPointer.cast());
      calloc.free(newTermIOSPointer);
    }
  }

  static final Stream<List<int>> _stdinBroadcast = shareReusableInputStream(
    stdin,
  );

  @override
  Stream<List<int>> openInputStream() => _stdinBroadcast;

  @override
  void disableRawMode() {
    if (_origTermIOSPointer == nullptr) return;
    _tcsetattr(_fd, _TCSANOW, _origTermIOSPointer);
    calloc.free(_origTermIOSPointer);
    _origTermIOSPointer = nullptr;
  }
}

/// Configures [target] for raw terminal mode on Linux (`glibc` ABI).
void configureLinuxRawTermIOS(LinuxTermIOS orig, LinuxTermIOS target) {
  target
    ..c_iflag =
        orig.c_iflag &
        ~(_LINUX_BRKINT |
            _LINUX_ICRNL |
            _LINUX_INPCK |
            _LINUX_ISTRIP |
            _LINUX_IXON)
    ..c_oflag = orig.c_oflag & ~_LINUX_OPOST
    ..c_cflag = (orig.c_cflag & ~_LINUX_CSIZE) | _LINUX_CS8
    ..c_lflag =
        orig.c_lflag &
        ~(_LINUX_ECHO | _LINUX_ICANON | _LINUX_IEXTEN | _LINUX_ISIG)
    ..c_line = orig.c_line
    ..c_cc = orig.c_cc
    ..c_cc[_LINUX_VMIN] = 0
    ..c_cc[_LINUX_VTIME] = 1
    ..c_ispeed = orig.c_ispeed
    ..c_ospeed = orig.c_ospeed;
}

/// Configures [target] for raw terminal mode on macOS / Darwin.
void configureDarwinRawTermIOS(DarwinTermIOS orig, DarwinTermIOS target) {
  target
    ..c_iflag =
        orig.c_iflag &
        ~(_DARWIN_BRKINT |
            _DARWIN_ICRNL |
            _DARWIN_INPCK |
            _DARWIN_ISTRIP |
            _DARWIN_IXON)
    ..c_oflag = orig.c_oflag & ~_DARWIN_OPOST
    ..c_cflag = (orig.c_cflag & ~_DARWIN_CSIZE) | _DARWIN_CS8
    ..c_lflag =
        orig.c_lflag &
        ~(_DARWIN_ECHO | _DARWIN_ICANON | _DARWIN_IEXTEN | _DARWIN_ISIG)
    ..c_cc = orig.c_cc
    ..c_cc[_DARWIN_VMIN] = 0
    ..c_cc[_DARWIN_VTIME] = 1
    ..c_ispeed = orig.c_ispeed
    ..c_ospeed = orig.c_ospeed;
}

// Common constants
const int _STDIN_FILENO = 0;
const int _TCSANOW = 0;

// Linux (<bits/termios-struct.h>, <bits/termios-c_*.h>) constants
const int _LINUX_BRKINT = 0x00000002;
const int _LINUX_INPCK = 0x00000010;
const int _LINUX_ISTRIP = 0x00000020;
const int _LINUX_ICRNL = 0x00000100;
const int _LINUX_IXON = 0x00000400;
const int _LINUX_OPOST = 0x00000001;
const int _LINUX_CSIZE = 0x00000030;
const int _LINUX_CS8 = 0x00000030;
const int _LINUX_ISIG = 0x00000001;
const int _LINUX_ICANON = 0x00000002;
const int _LINUX_ECHO = 0x00000008;
const int _LINUX_IEXTEN = 0x00008000;
const int _LINUX_VTIME = 5;
const int _LINUX_VMIN = 6;
const int _LINUX_NCCS = 32;

// macOS / Darwin (<sys/termios.h>) constants
const int _DARWIN_BRKINT = 0x00000002;
const int _DARWIN_INPCK = 0x00000010;
const int _DARWIN_ISTRIP = 0x00000020;
const int _DARWIN_ICRNL = 0x00000100;
const int _DARWIN_IXON = 0x00000200;
const int _DARWIN_OPOST = 0x00000001;
const int _DARWIN_CSIZE = 0x00000300;
const int _DARWIN_CS8 = 0x00000300;
const int _DARWIN_ECHO = 0x00000008;
const int _DARWIN_ISIG = 0x00000080;
const int _DARWIN_ICANON = 0x00000100;
const int _DARWIN_IEXTEN = 0x00000400;
const int _DARWIN_VMIN = 16;
const int _DARWIN_VTIME = 17;
const int _DARWIN_NCCS = 20;

typedef cc_t = UnsignedChar;

/// Linux `glibc` `struct termios` (60 bytes on x86_64/arm64).
final class LinuxTermIOS extends Struct {
  @Uint32()
  external int c_iflag; // input mode flags (offset 0)
  @Uint32()
  external int c_oflag; // output mode flags (offset 4)
  @Uint32()
  external int c_cflag; // control mode flags (offset 8)
  @Uint32()
  external int c_lflag; // local mode flags (offset 12)
  @cc_t()
  external int c_line; // line discipline (offset 16)
  @Array(_LINUX_NCCS)
  external Array<cc_t> c_cc; // control characters (offset 17..48)
  @Uint32()
  external int c_ispeed; // input speed (offset 52)
  @Uint32()
  external int c_ospeed; // output speed (offset 56)
}

/// macOS / Darwin `struct termios` (72 bytes on 64-bit).
final class DarwinTermIOS extends Struct {
  @UnsignedLong()
  external int c_iflag; // input flags
  @UnsignedLong()
  external int c_oflag; // output flags
  @UnsignedLong()
  external int c_cflag; // control flags
  @UnsignedLong()
  external int c_lflag; // local flags
  @Array(_DARWIN_NCCS)
  external Array<cc_t> c_cc; // control chars
  @UnsignedLong()
  external int c_ispeed; // input speed
  @UnsignedLong()
  external int c_ospeed; // output speed
}

typedef TermIOS = LinuxTermIOS;

// int tcgetattr(int, struct termios *);
typedef TCGetAttrNative = Int32 Function(Int32 fildes, Pointer<Void> termios);
typedef TCGetAttrDart = int Function(int fildes, Pointer<Void> termios);

// int tcsetattr(int, int, const struct termios *);
typedef TCSetAttrNative =
    Int32 Function(Int32 fildes, Int32 optional_actions, Pointer<Void> termios);
typedef TCSetAttrDart =
    int Function(int fildes, int optional_actions, Pointer<Void> termios);
