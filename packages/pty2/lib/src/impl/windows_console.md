---
layout: Conceptual
title: Creating a Pseudoconsole session - Windows Console | Microsoft Learn
canonicalUrl: https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session
uhfHeaderId: MSDocsHeader-Windows
ms.subservice: windows-console
ms.topic: reference
ms.date: 2018-07-12T00:00:00.0000000Z
ms.service: windows
breadcrumb_path: /windows/console/breadcrumb/toc.json
feedback_system: Standard
feedback_product_url: https://github.com/microsoft/terminal/issues
feedback_help_link_url: https://learn.microsoft.com/answers/
feedback_help_link_type: get-help-at-qna
description: A pseudoconsole session will allow an application to host the activities of a character-mode application
author: miniksa
ms.author: miniksa
keywords: console, character mode applications, command line applications, terminal applications, console api, conpty, pseudoconsole, windows pty, pseudo console
locale: en-us
document_id: 09ed724a-32d9-72fc-a938-e181e3fde0e8
document_version_independent_id: d6706818-fb3d-7400-a549-9d3a77602f33
updated_at: 2025-08-05T17:49:00.0000000Z
original_content_git_url: https://github.com/MicrosoftDocs/Console-Docs/blob/live/docs/creating-a-pseudoconsole-session.md
gitcommit: https://github.com/MicrosoftDocs/Console-Docs/blob/c3035561c145c6c6c6b0d7a4f49a6d706256451e/docs/creating-a-pseudoconsole-session.md
git_commit_id: c3035561c145c6c6c6b0d7a4f49a6d706256451e
site_name: Docs
depot_name: MSDN.console
page_type: conceptual
toc_rel: toc.json
pdf_url_template: https://learn.microsoft.com/pdfstore/en-us/MSDN.console/{branchName}{pdfName}
word_count: 1610
asset_id: creating-a-pseudoconsole-session
moniker_range_name:
monikers: []
item_type: Content
source_path: docs/creating-a-pseudoconsole-session.md
cmProducts:
- https://authoring-docs-microsoft.poolparty.biz/devrel/bcbcbad5-4208-4783-8035-8481272c98b8
- https://authoring-docs-microsoft.poolparty.biz/devrel/540ac133-a371-4dbb-8f94-28d6cc77a70b
spProducts:
- https://authoring-docs-microsoft.poolparty.biz/devrel/43b2e5aa-8a6d-4de2-a252-692232e5edc8
- https://authoring-docs-microsoft.poolparty.biz/devrel/60bfc045-f127-4841-9d00-ea35495a5800
platformId: fbc3b0cd-84c5-69dd-0cc1-bb9a90731fd7
---

# Creating a Pseudoconsole session - Windows Console | Microsoft Learn

The Windows Pseudoconsole, sometimes also referred to as pseudo console, ConPTY, or the Windows PTY, is a mechanism designed for creating an external host for character-mode subsystem activities that replace the user interactivity portion of the default console host window.

Hosting a pseudoconsole session is a bit different than a traditional console session. Traditional console sessions automatically start when the operating system recognizes that a character-mode application is about to run. In contrast, a pseudoconsole session and the communication channels need to be created by the hosting application prior to creating the process with the child character-mode application to be hosted. The child process will still be created using the [**CreateProcess**](/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa) function, but with some additional information that will direct the operating system to establish the appropriate environment.

You can find additional background information about this system on the [initial announcement blog post](https://blogs.msdn.microsoft.com/commandline/2018/08/02/windows-command-line-introducing-the-windows-pseudo-console-conpty/).

Complete examples of using the Pseudoconsole are available on our GitHub repository [microsoft/terminal](https://github.com/microsoft/terminal) in the samples directory.

## Preparing the communication channels

The first step is to create a pair of synchronous communication channels that will be provided during creation of the pseudoconsole session for bidirectional communication with the hosted application. These channels are processed by the pseudoconsole system using [**ReadFile**](/en-us/windows/desktop/api/fileapi/nf-fileapi-readfile) and [**WriteFile**](/en-us/windows/desktop/api/fileapi/nf-fileapi-writefile) with [synchronous I/O](/en-us/windows/desktop/Sync/synchronization-and-overlapped-input-and-output). File or I/O device handles like a file stream or pipe are acceptable as long as an [**OVERLAPPED**](/en-us/windows/desktop/api/minwinbase/ns-minwinbase-overlapped) structure is not required for asynchronous communication.

Warning

To prevent race conditions and deadlocks, we highly recommend that each of the communication channels is serviced on a separate thread that maintains its own client buffer state and messaging queue inside your application. Servicing all of the pseudoconsole activities on the same thread may result in a deadlock where one of the communications buffers is filled and waiting for your action while you attempt to dispatch a blocking request on another channel.

## Creating the Pseudoconsole

With the communications channels that have been established, identify the "read" end of the input channel and the "write" end of the output channel. This pair of handles is provided on calling [**CreatePseudoConsole**](createpseudoconsole) to create the object.

On creation, a size representing the X and Y dimensions (in count of characters) is required. These are the dimensions that will apply to the display surface for the final (terminal) presentation window. The values are used to create an in-memory buffer inside the pseudoconsole system.

The buffer size provide answers to client character-mode applications that probe for information using the [client-side console functions](console-functions) like [**GetConsoleScreenBufferInfoEx**](getconsolescreenbufferinfoex) and dictates the layout and positioning of text when clients use functions like [**WriteConsoleOutput**](writeconsoleoutput).

Finally, a flags field is provided on creation of a pseudoconsole to perform special functionality. By default, set this to 0 to have no special functionality.

At this time, only one special flag is available to request the inheritence of the cursor position from a console session already attached to the caller of the pseudoconsole API. This is intended for use in more advanced scenarios where a hosting application that is preparing a pseudoconsole session is itself also a client character-mode application of a another console environment.

A sample snippet is provided below utilizing [**CreatePipe**](/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe) to establish a pair of communication channels and create the pseudoconsole.

```C

HRESULT SetUpPseudoConsole(COORD size)
{
    HRESULT hr = S_OK;

    // Create communication channels

    // - Close these after CreateProcess of child application with pseudoconsole object.
    HANDLE inputReadSide, outputWriteSide;

    // - Hold onto these and use them for communication with the child through the pseudoconsole.
    HANDLE outputReadSide, inputWriteSide;

    if (!CreatePipe(&inputReadSide, &inputWriteSide, NULL, 0))
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    if (!CreatePipe(&outputReadSide, &outputWriteSide, NULL, 0))
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    HPCON hPC;
    hr = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, &hPC);
    if (FAILED(hr))
    {
        return hr;
    }

    // ...

}
```

Note

This snippet is incomplete and used for demonstration of this specific call only. You will need to manage the lifetime of the **HANDLE**s appropriately. Failure to manage the lifetime of **HANDLE**s correctly can result in deadlock scenarios, especially with synchronous I/O calls.

Upon completion of the [**CreateProcess**](/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa) call to create the client character-mode application attached to the pseudoconsole, the handles given during creation should be freed from this process. This will decrease the reference count on the underlying device object and allow I/O operations to properly detect a broken channel when the pseudoconsole session closes its copy of the handles.

## Preparing for Creation of the Child Process

The next phase is to prepare the [**STARTUPINFOEX**](/en-us/windows/desktop/api/winbase/ns-winbase-startupinfoexw) structure that will convey the pseudoconsole information while starting the child process.

This structure contains the ability to provide complex startup information including attributes for process and thread creation.

Use [**InitializeProcThreadAttributeList**](/en-us/windows/desktop/api/processthreadsapi/nf-processthreadsapi-initializeprocthreadattributelist) in a double-call fashion to first calculate the number of bytes required to hold the list, allocate the memory requested, then call again providing the opaque memory pointer to have it set up as the attribute list.

Next, call [**UpdateProcThreadAttribute**](/en-us/windows/desktop/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute) passing the initialized attribute list with the flag **PROC\_THREAD\_ATTRIBUTE\_PSEUDOCONSOLE**, the pseudoconsole handle, and the size of the pseudoconsole handle.

```C

HRESULT PrepareStartupInformation(HPCON hpc, STARTUPINFOEX* psi)
{
    // Prepare Startup Information structure
    STARTUPINFOEX si;
    ZeroMemory(&si, sizeof(si));
    si.StartupInfo.cb = sizeof(STARTUPINFOEX);

    // Discover the size required for the list
    size_t bytesRequired;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytesRequired);

    // Allocate memory to represent the list
    si.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, bytesRequired);
    if (!si.lpAttributeList)
    {
        return E_OUTOFMEMORY;
    }

    // Initialize the list memory location
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &bytesRequired))
    {
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        return HRESULT_FROM_WIN32(GetLastError());
    }

    // Set the pseudoconsole information into the list
    if (!UpdateProcThreadAttribute(si.lpAttributeList,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hpc,
                                   sizeof(hpc),
                                   NULL,
                                   NULL))
    {
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        return HRESULT_FROM_WIN32(GetLastError());
    }

    *psi = si;

    return S_OK;
}

```

## Creating the Hosted Process

Next, call [**CreateProcess**](/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa) passing the [**STARTUPINFOEX**](/en-us/windows/win32/api/winbase/ns-winbase-startupinfoexw) structure along with the path to the executable and any additional configuration information if applicable. It is important to set the **EXTENDED\_STARTUPINFO\_PRESENT** flag when calling to alert the system that the pseudoconsole reference is contained in the extended information.

```C
HRESULT SetUpPseudoConsole(COORD size)
{
    // ...

    PCWSTR childApplication = L"C:\\windows\\system32\\cmd.exe";

    // Create mutable text string for CreateProcessW command line string.
    const size_t charsRequired = wcslen(childApplication) + 1; // +1 null terminator
    PWSTR cmdLineMutable = (PWSTR)HeapAlloc(GetProcessHeap(), 0, sizeof(wchar_t) * charsRequired);

    if (!cmdLineMutable)
    {
        return E_OUTOFMEMORY;
    }

    wcscpy_s(cmdLineMutable, charsRequired, childApplication);

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    // Call CreateProcess
    if (!CreateProcessW(NULL,
                        cmdLineMutable,
                        NULL,
                        NULL,
                        FALSE,
                        EXTENDED_STARTUPINFO_PRESENT,
                        NULL,
                        NULL,
                        &siEx.StartupInfo,
                        &pi))
    {
        HeapFree(GetProcessHeap(), 0, cmdLineMutable);
        return HRESULT_FROM_WIN32(GetLastError());
    }

    // ...
}
```

Note

Closing the pseudoconsole session while the hosted process is still starting up and connecting can result in an error dialog being shown by the client application. The same error dialog is shown if the hosted process is given an invalid pseudoconsole handle for startup. To the hosted process initialization code, the two circumstances are identical. The pop-up dialog from the hosted client application on failure will read `0xc0000142` with a localized message detailing failure to initialize.

## Communicating with the Pseudoconsole Session

Once the process is created successfully, the hosting application can use the write end of the input pipe to send user interaction information into the pseudoconsole and the read end of the output pipe to receive graphical presentation information from the pseudo console.

It is completely up to the hosting application to decide how to handle further activity. The hosting application could launch a window in another thread to collect user interaction input and serialize it into the write end of the input pipe for the pseudoconsole and the hosted character-mode application. Another thread could be launched to drain the read end of the output pipe for the pseudoconsole, decode the text and [virtual terminal sequence](console-virtual-terminal-sequences) information, and present that to the screen.

Threads could also be used to relay the information from the pseudoconsole channels out to a different channel or device including a network to remote information to another process or machine and avoiding any local transcoding of the information.

## Resizing the Pseudoconsole

Throughout the course of runtime, there may be a circumstance by which the size of the buffer needs to be changed due to a user interaction or a request received out of band from another display/interaction device.

This can be done with the [**ResizePseudoConsole**](resizepseudoconsole) function specifying both the height and width of the buffer in a count of characters.

```C
// Theoretical event handler function with theoretical
// event that has associated display properties
// on Source property.
void OnWindowResize(Event e)
{
    // Retrieve width and height dimensions of display in
    // characters using theoretical height/width functions
    // that can retrieve the properties from the display
    // attached to the event.
    COORD size;
    size.X = GetViewWidth(e.Source);
    size.Y = GetViewHeight(e.Source);

    // Call pseudoconsole API to inform buffer dimension update
    ResizePseudoConsole(m_hpc, size);
}
```

## Ending the Pseudoconsole Session

To end the session, call the [**ClosePseudoConsole**](closepseudoconsole) function with the handle from the original pseudoconsole creation. Any attached client character-mode applications, such as the one from the [**CreateProcess**](/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa) call, will be terminated when the session is closed. If the original child was a shell-type application that creates other processes, any related attached processes in the tree will also be terminated.

Warning

Closing the session has several side effects which can result in a deadlock condition if the pseudoconsole is used in a single-threaded synchronous fashion. The act of closing the pseudoconsole session may emit a final frame update to `hOutput` which should be drained from the communications channel buffer. Additionally, if `PSEUDOCONSOLE_INHERIT_CURSOR` was selected while creating the pseudoconsole, attempting to close the pseudoconsole without responding to the cursor inheritence query message (received on `hOutput` and replied to via `hInput`) may result in another deadlock condition. It is recommended that communications channels for the pseudoconsole are serviced on individual threads and remain drained and processed until broken of their own accord by the client application exiting or by the completion of teardown activities in calling the [**ClosePseudoConsole**](closepseudoconsole) function.