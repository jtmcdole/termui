import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:termui/terminal/raw/unix_terminal.dart';
import 'package:test/test.dart';

typedef _OpenPtyNative =
    Int32 Function(
      Pointer<Int32> amaster,
      Pointer<Int32> aslave,
      Pointer<Char> name,
      Pointer<Void> termp,
      Pointer<Void> winp,
    );
typedef _OpenPtyDart =
    int Function(
      Pointer<Int32> amaster,
      Pointer<Int32> aslave,
      Pointer<Char> name,
      Pointer<Void> termp,
      Pointer<Void> winp,
    );

typedef _CloseNative = Int32 Function(Int32 fd);
typedef _CloseDart = int Function(int fd);

void main() {
  group('UnixTerminal & TermIOS ABI (P0-1)', () {
    test('LinuxTermIOS matches 60-byte glibc struct termios layout', () {
      expect(sizeOf<LinuxTermIOS>(), equals(60));

      final ptr = calloc<LinuxTermIOS>();
      try {
        final bytes = ptr.cast<Uint8>().asTypedList(60);
        ptr.ref.c_iflag = 0x11223344;
        ptr.ref.c_oflag = 0x55667788;
        ptr.ref.c_cflag = 0x99AABBCC;
        ptr.ref.c_lflag = 0xDDEEFF00;
        ptr.ref.c_line = 0x42;
        ptr.ref.c_cc[0] = 0xAA;
        ptr.ref.c_cc[31] = 0xBB;
        ptr.ref.c_ispeed = 0x12345678;
        ptr.ref.c_ospeed = 0x87654321;

        final u32 = ptr.cast<Uint32>().asTypedList(15);
        expect(u32[0], equals(0x11223344)); // offset 0: c_iflag
        expect(u32[1], equals(0x55667788)); // offset 4: c_oflag
        expect(u32[2], equals(0x99AABBCC)); // offset 8: c_cflag
        expect(u32[3], equals(0xDDEEFF00)); // offset 12: c_lflag
        expect(bytes[16], equals(0x42)); // offset 16: c_line
        expect(bytes[17], equals(0xAA)); // offset 17: c_cc[0]
        expect(bytes[48], equals(0xBB)); // offset 48: c_cc[31]
        expect(u32[13], equals(0x12345678)); // offset 52: c_ispeed
        expect(u32[14], equals(0x87654321)); // offset 56: c_ospeed
      } finally {
        calloc.free(ptr);
      }
    });

    test(
      'configureLinuxRawTermIOS preserves c_oflag/c_ospeed and sets raw flags',
      () {
        final orig = calloc<LinuxTermIOS>();
        final target = calloc<LinuxTermIOS>();
        try {
          orig.ref
            ..c_iflag = 0xFFFFFFFF
            ..c_oflag =
                0x00000005 // OPOST (0x1) | ONLCR (0x4)
            ..c_cflag = 0x00000000
            ..c_lflag = 0xFFFFFFFF
            ..c_line = 3
            ..c_ispeed = 38400
            ..c_ospeed = 115200;
          orig.ref.c_cc[5] = 99; // VTIME
          orig.ref.c_cc[6] = 99; // VMIN

          configureLinuxRawTermIOS(orig.ref, target.ref);

          // c_oflag must have OPOST (0x1) cleared, leaving 0x4, and NOT be clobbered by c_ospeed
          expect(target.ref.c_oflag, equals(0x00000004));
          expect(target.ref.c_ispeed, equals(38400));
          expect(target.ref.c_ospeed, equals(115200));
          expect(target.ref.c_line, equals(3));

          // BRKINT(0x2) | INPCK(0x10) | ISTRIP(0x20) | ICRNL(0x100) | IXON(0x400) cleared
          expect(target.ref.c_iflag & 0x0532, equals(0));
          // CS8 (0x30) set
          expect(target.ref.c_cflag & 0x0030, equals(0x0030));
          // ISIG(0x1) | ICANON(0x2) | ECHO(0x8) | IEXTEN(0x8000) cleared
          expect(target.ref.c_lflag & 0x800B, equals(0));
          // Linux VTIME=5 is 1, VMIN=6 is 0
          expect(target.ref.c_cc[5], equals(1));
          expect(target.ref.c_cc[6], equals(0));
        } finally {
          calloc.free(orig);
          calloc.free(target);
        }
      },
    );

    test(
      'configureDarwinRawTermIOS preserves c_oflag/c_ospeed and sets Darwin raw flags',
      () {
        final orig = calloc<DarwinTermIOS>();
        final target = calloc<DarwinTermIOS>();
        try {
          orig.ref
            ..c_iflag = 0xFFFFFFFF
            ..c_oflag = 0x00000003
            ..c_cflag = 0x00000000
            ..c_lflag = 0xFFFFFFFF
            ..c_ispeed = 9600
            ..c_ospeed = 57600;

          configureDarwinRawTermIOS(orig.ref, target.ref);

          expect(target.ref.c_oflag, equals(0x00000002));
          expect(target.ref.c_ispeed, equals(9600));
          expect(target.ref.c_ospeed, equals(57600));
          expect(target.ref.c_iflag & 0x0332, equals(0));
          expect(target.ref.c_cflag & 0x0300, equals(0x0300));
          expect(target.ref.c_lflag & 0x0588, equals(0));
          // Darwin VMIN=16 is 0, VTIME=17 is 1
          expect(target.ref.c_cc[16], equals(0));
          expect(target.ref.c_cc[17], equals(1));
        } finally {
          calloc.free(orig);
          calloc.free(target);
        }
      },
    );

    test(
      'UnixTerminal enableRawMode/disableRawMode round-trip and re-entry on Linux PTY',
      () {
        if (!Platform.isLinux) return;

        final libc = DynamicLibrary.open('libc.so.6');
        final openpty = libc.lookupFunction<_OpenPtyNative, _OpenPtyDart>(
          'openpty',
        );
        final closeFd = libc.lookupFunction<_CloseNative, _CloseDart>('close');
        final tcgetattr = libc.lookupFunction<TCGetAttrNative, TCGetAttrDart>(
          'tcgetattr',
        );

        final masterPtr = calloc<Int32>();
        final slavePtr = calloc<Int32>();
        try {
          final res = openpty(masterPtr, slavePtr, nullptr, nullptr, nullptr);
          expect(res, equals(0));

          final masterFd = masterPtr.value;
          final slaveFd = slavePtr.value;
          final inspectPtr = calloc<LinuxTermIOS>();
          try {
            final term = UnixTerminal(fd: slaveFd);

            // Initially cooked mode on fresh PTY (ICANON and ECHO enabled)
            expect(tcgetattr(slaveFd, inspectPtr.cast()), equals(0));
            final initialLflag = inspectPtr.ref.c_lflag;
            expect(initialLflag & 0x000A, isNot(equals(0))); // ICANON | ECHO

            // 1st enableRawMode
            term.enableRawMode();
            expect(tcgetattr(slaveFd, inspectPtr.cast()), equals(0));
            expect(inspectPtr.ref.c_lflag & 0x800B, equals(0));
            expect(inspectPtr.ref.c_oflag & 0x0001, equals(0));
            expect(inspectPtr.ref.c_cc[6], equals(0)); // VMIN
            expect(inspectPtr.ref.c_cc[5], equals(1)); // VTIME

            // 1st disableRawMode restores initial cooked flags
            term.disableRawMode();
            expect(tcgetattr(slaveFd, inspectPtr.cast()), equals(0));
            expect(inspectPtr.ref.c_lflag, equals(initialLflag));

            // 2nd enableRawMode after disableRawMode must NOT dereference nullptr
            term.enableRawMode();
            expect(tcgetattr(slaveFd, inspectPtr.cast()), equals(0));
            expect(inspectPtr.ref.c_lflag & 0x800B, equals(0));

            term.disableRawMode();
            expect(tcgetattr(slaveFd, inspectPtr.cast()), equals(0));
            expect(inspectPtr.ref.c_lflag, equals(initialLflag));
          } finally {
            calloc.free(inspectPtr);
            closeFd(slaveFd);
            closeFd(masterFd);
          }
        } finally {
          calloc.free(masterPtr);
          calloc.free(slavePtr);
        }
      },
    );
  });
}
