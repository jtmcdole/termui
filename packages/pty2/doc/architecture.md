# `package:pty2` System Architecture

## 1. System Design Overview

`package:pty2` manages pseudo-terminal (PTY) lifecycles by calling native OS APIs through Dart FFI. To keep the caller isolate's single-threaded event loop responsive, `BlockingPseudoTerminal` moves blocking native I/O off the main isolate onto three dedicated background isolates:

- The reader isolate (`_readUntilExit`) blocks on PTY output reads and stitches split UTF-8 sequences.
- The writer isolate (`_writeUntilClosed`) drains queued input writes in FIFO order so full OS pipe buffers never block the caller or deadlock `ackProcessed: true` flows.
- The exit-waiter isolate (`_waitForExitCode`) blocks until the child process exits and reports its exit code.

```mermaid
graph TD
    %% Main Isolate
    subgraph MainIsolate ["Main Isolate (Event Loop)"]
        PT[PseudoTerminal API]
        BPT[BlockingPseudoTerminal]
        OC[StreamController out]
    end

    %% Writer Isolate
    subgraph WriterIsolate ["Writer Isolate"]
        WU["_writeUntilClosed()"]
    end

    %% Reader Isolate
    subgraph ReaderIsolate ["Reader Isolate"]
        RU["_readUntilExit()"]
        US["input.stream (sync)"]
        UD["Utf8Decoder (Stateful)"]
    end

    %% OS Layer
    subgraph Kernel ["OS Kernel"]
        StdinPipe["Stdin Pipe / PTY Master"]
        StdoutPipe["Stdout Pipe / PTY Master"]
        ChildProc["Child Process (Shell)"]
    end

    %% Data Flow
    PT -->|1. write string| BPT
    BPT -->|2. SendPort TransferableTypedData| WU
    WU -->|3. Overlapped WriteFile / poll+write| StdinPipe
    StdinPipe --> ChildProc

    ChildProc --> StdoutPipe
    StdoutPipe -->|4. FFI ReadFile / poll+read| RU
    RU -->|5. Uint8List raw bytes| US
    US -->|6. Stateful UTF-8 stitching| UD
    UD -->|7. SendPort String| BPT
    BPT -->|8. sink.add| OC
    OC -->|9. Stream listen| User["User App"]
```

---

## 2. Sequence Diagrams

### 2.1 PTY Open (`PseudoTerminal.start`)

Sets up native FFI structures and pipes, starts the child process inside the PTY, and launches the reader, writer, and exit-waiter isolates.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant OS as OS FFI (ConPTY / openpty)
    participant Writer as Writer Isolate
    participant Reader as Reader Isolate

    User->>BPT: PseudoTerminal.start(exec, args)
    activate BPT
    BPT->>OS: PtyCore.start()
    Note over OS: Windows: Overlapped named input pipe + ConPTY + CreateProcessW<br/>Unix: openpty (O_NONBLOCK) + reaper shim + execve
    OS-->>BPT: PtyCore instance (Native Handles)
    BPT->>Writer: Isolate.spawn(_writeUntilClosed, core.takeWriter())
    BPT->>Reader: Isolate.spawn(_readUntilExit, core.worker)
    Writer-->>BPT: SendPort (flushes pre-ready writes)
    Reader-->>BPT: SendPort (ackProcessed channel)
    BPT-->>User: PseudoTerminal instance
    deactivate BPT
```

### 2.2 PTY Send (`write`)

Encodes text to UTF-8 and transfers the bytes asynchronously to the writer isolate in FIFO order without blocking the caller isolate.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant Writer as Writer Isolate
    participant OS as OS FFI (WriteFile / write)

    User->>BPT: write("command\n")
    activate BPT
    Note over BPT: Encode UTF-8 and queue TransferableTypedData
    BPT->>Writer: SendPort.send(bytes)
    BPT-->>User: return immediately
    deactivate BPT
    activate Writer
    Writer->>OS: PtyCoreWriter.write(bytes)
    Note over OS: Windows: Overlapped WriteFile + WaitForMultipleObjects(stopEvent, ioEvent)<br/>Unix: non-blocking write(writerPtm) + 50 ms poll(POLLOUT)
    OS-->>Writer: PtyWriteStatus.written
    deactivate Writer
```

### 2.3 PTY Read

The reader isolate waits on the PTY output handle, decodes bytes statefully across multi-byte UTF-8 boundaries, and sends strings back to the main isolate. When `ackProcessed: true`, it pauses after each chunk until the caller acknowledges processing.

```mermaid
sequenceDiagram
    autonumber
    participant OS as OS FFI (ReadFile / read)
    participant Reader as Reader Isolate
    participant Main as Main Isolate
    actor User as User App

    loop Read Loop
        Reader->>OS: PtyCoreWorker.read() (blocking)
        activate OS
        Note over OS: Suspends reader thread until bytes arrive or EOF
        OS-->>Reader: Uint8List raw bytes
        deactivate OS
        Reader->>Reader: Stream.transform(Utf8Decoder)
        Note over Reader: Buffers split multi-byte UTF-8 sequences
        Reader->>Main: SendPort.send(String)
        Main->>User: StreamController.out.add(String)
    end
```

### 2.4 PTY Resize

Updates the PTY window dimensions in character cells (and optional viewport pixels on Unix).

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant OS as OS FFI (Resize / ioctl)

    User->>BPT: resize(cols, rows)
    activate BPT
    BPT->>OS: PtyCore.resize(cols, rows)
    Note over OS: Windows: ResizePseudoConsole<br/>Unix: ioctl(ptm, TIOCSWINSZ)
    OS-->>BPT: return
    BPT-->>User: return
    deactivate BPT
```

### 2.5 PTY Close (`kill` / natural exit)

Stops pending writes, terminates the child process, cancels any blocked writer I/O, and releases native buffers and OS handles once all isolates exit.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant Writer as Writer Isolate
    participant Reader as Reader Isolate
    participant OS as OS FFI

    User->>BPT: kill()
    activate BPT
    BPT->>Writer: SendPort.send(null)
    BPT->>OS: PtyCore.kill()
    Note over OS: Windows: SetEvent(stopEvent) + TerminateProcess + ClosePseudoConsole<br/>Unix: kill(-pgid, sig) + set stop_flag + close(mainPtm)
    OS-->>BPT: return
    deactivate BPT
    Note over Writer: Wakes via stopEvent (CancelIoEx + GetOverlappedResult) or stop_flag
    Writer->>Writer: writer.free() and close ReceivePort
    Reader->>Reader: worker.free() and send EOF null
    BPT->>User: Future<exitCode> completes and out stream closes
```
