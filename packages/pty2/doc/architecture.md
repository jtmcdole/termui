# `package:pty2` System Architecture

## 1. System Design Overview
`package:pty2` manages pseudo-terminal (PTY) lifecycles by wrapping native OS system calls via Dart FFI. To prevent blocking the main Dart isolate's single-threaded event loop during synchronous native I/O, it splits execution into a **Controller Isolate** (Main thread) and a **Worker Isolate** (Read Thread).

```mermaid
graph TD
    %% Main Isolate
    subgraph MainIsolate ["Main Isolate (Event Loop)"]
        PT[PseudoTerminal API]
        BPT[BlockingPseudoTerminal]
        OC[StreamController out]
    end

    %% Worker Isolate
    subgraph WorkerIsolate ["Worker Isolate (Spawned Thread)"]
        RU["_readUntilExit()"]
        US["input.stream (StreamController sync)"]
        UD["Utf8Decoder (Stateful)"]
    end

    %% OS Layer
    subgraph Kernel ["OS Kernel"]
        StdinPipe["Stdin Pipe"]
        StdoutPipe["Stdout Pipe"]
        ChildProc["Child Process (Shell)"]
    end

    %% Data Flow
    PT -->|1. write string| BPT
    BPT -->|2. FFI WriteFile/write| StdinPipe
    StdinPipe --> ChildProc

    ChildProc --> StdoutPipe
    StdoutPipe -->|3. FFI ReadFile/read blocks thread| RU
    RU -->|4. Uint8List raw bytes| US
    US -->|5. Stateful UTF-8 Chunk Stitching| UD
    UD -->|6. SendPort.send String| BPT
    BPT -->|7. sink.add| OC
    OC -->|8. Stream listen| User["User App"]
```

---

## 2. Sequence Diagrams

### 2.1 PTY Open (`PseudoTerminal.start`)
Sets up FFI structures, pipes, spawns the child process inside the PTY container, and spins up the worker isolate.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant OS as OS FFI (ConPTY / forkpty)
    participant Worker as Worker Isolate

    User->>BPT: PseudoTerminal.start(exec, args)
    activate BPT
    BPT->>OS: PtyCore.start()
    Note over OS: Windows: CreatePseudoConsole + CreateProcessW<br/>Unix: forkpty + execve
    OS-->>BPT: PtyCore instance (Native Handles)
    BPT->>Worker: Isolate.spawn(_readUntilExit, PtyCore)
    activate Worker
    Worker-->>BPT: SendPort (ack sync channels)
    BPT-->>User: PseudoTerminal Instance
    deactivate BPT
    deactivate Worker
```

### 2.2 PTY Send (`write`)
Synchronously encodes characters to UTF-8 and passes them directly to the input write pipe via FFI on the main isolate.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant OS as OS FFI (WriteFile / write)

    User->>BPT: write("command\n")
    activate BPT
    Note over BPT: Encode string to UTF-8 bytes
    BPT->>OS: PtyCore.write(bytes)
    Note over OS: Win32: WriteFile<br/>Unix: write(ptm)
    OS-->>BPT: return
    BPT-->>User: return
    deactivate BPT
```

### 2.3 PTY Read
The worker isolate blocks on the output read side of the OS pipe. When data is available, it decodes it statefully (safeguarding split UTF-8 multi-byte sequences) and dispatches it asynchronously to the main isolate.

```mermaid
sequenceDiagram
    autonumber
    participant OS as OS FFI (ReadFile / read)
    participant Worker as Worker Isolate
    participant Main as Main Isolate
    actor User as User App

    loop Infinite Read Loop
        Worker->>OS: PtyCore.read() (BLOCKING CALL)
        activate OS
        Note over OS: Suspends Worker OS Thread until data arrives
        OS-->>Worker: Uint8List raw bytes
        deactivate OS
        Worker->>Worker: Stream.transform(Utf8Decoder)
        Note over Worker: Accumulates split multibyte sequences
        Worker->>Main: SendPort.send(String)
        Main->>User: StreamController.out.add(String)
    end
```

### 2.4 PTY Resize
Changes physical width and height dimensions of the virtual console buffer.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant OS as OS FFI (Resize / ioctl)

    User->>BPT: resize(cols, rows)
    activate BPT
    BPT->>OS: PtyCore.resize(cols, rows)
    Note over OS: Win32: ResizePseudoConsole<br/>Unix: ioctl(ptm, TIOCSWINSZ)
    OS-->>BPT: return
    BPT-->>User: return
    deactivate BPT
```

### 2.5 PTY Close (`kill` / `exit`)
Terminates the spawned process, closes native handles, and tears down the isolates.

```mermaid
sequenceDiagram
    autonumber
    actor User as Main Isolate
    participant BPT as BlockingPseudoTerminal
    participant Worker as Worker Isolate
    participant OS as OS FFI (Kill / Close)

    User->>BPT: kill()
    activate BPT
    BPT->>OS: PtyCore.kill()
    Note over OS: Win32: TerminateProcess + ClosePseudoConsole<br/>Unix: kill(pid, SIGKILL)
    OS-->>BPT: return
    BPT->>Worker: Tear down (Send null message)
    deactivate BPT
    Worker->>Worker: Close StreamController
    destroy Worker
    Worker-->>BPT: Worker Exited
    activate BPT
    BPT->>User: Future<exitCode> completes
    deactivate BPT
```
