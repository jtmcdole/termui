## 0.5.3

 - **REFACTOR**(core): optimize render loops and decouple audio state.
 - **FIX**: racy test in pty2.

## 0.5.2

 - **FIX**(pty2): resolve ConPTY initialization failures and test hangs.
 - **FIX**(pty2): quote Windows command line tokens and enable ConPTY inside automated tests.
 - **FIX**(pty2): correct ioctl FFI varargs and remove automatic login shell flag.

## 0.5.1

 - **FIX**(tests): github actions exercised different pathways in the testing.
 - **FIX**(pty2): resolve fork deadlocks by replacing forkpty with native openpty and eagerly-resolved POSIX calls.
 - **FIX**(pty2): pre-evaluate properties before forkpty to avoid deadlocks.
 - **FIX**(pty2): strictly enforce POSIX async-signal-safety post-fork.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.

## 0.5.0

> Note: This release has breaking changes.

 - **DOCS**: fixing up documentation.
 - **BREAKING** **FEAT**(pty2): add pty2 package for cross-platform pseudo-terminals.

## 0.4.0

The real fix for Windows being flakey: "more data in buffer" was treated as an error instead of just reading again. "ERROR_SUCCESS" is such a great enum.

- Upgrade win32 to 6.0
- Upgrade ffi to 2.2.0
- Removed _NamedPipe for windows.


## 0.2.2-pre

- Upgrade win32 package to 2.1.x
- Fix Windows stdio handle leak issue.

## 0.2.1-pre

- Bugfix: path error macos zsh [#4](https://github.com/TerminalStudio/pty/pull/4), thanks [@devmil](https://github.com/devmil)

## 0.2.0-pre

- Using forkpty to set up the pty connection [#2](https://github.com/TerminalStudio/pty/pull/2), thanks [@devmil](https://github.com/devmil)

## 0.1.1

- Fix pid reference

## 0.1.0

- Migrate to nnbd

## 0.0.1

- Initial version
