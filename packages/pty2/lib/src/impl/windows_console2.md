

```cpp
    // Note: Most error checking removed for brevity.
    // ...

    // Initializes the specified startup info struct with the required properties and
    // updates its thread attribute list with the specified ConPTY handle
    HRESULT InitializeStartupInfoAttachedToConPTY(STARTUPINFOEX* siEx, HPCON hPC)
    {
        HRESULT hr = E_UNEXPECTED;
        size_t size;

        siEx->StartupInfo.cb = sizeof(STARTUPINFOEX);

        // Create the appropriately sized thread attribute list
        InitializeProcThreadAttributeList(NULL, 1, 0, &size);
        std::unique_ptr<BYTE[]> attrList = std::make_unique<BYTE[]>(size);

        // Set startup info's attribute list & initialize it
        siEx->lpAttributeList = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(
            attrList.get());
        bool fSuccess = InitializeProcThreadAttributeList(
            siEx->lpAttributeList, 1, 0, (PSIZE_T)&size);

        if (fSuccess)
        {
            // Set thread attribute list's Pseudo Console to the specified ConPTY
            fSuccess = UpdateProcThreadAttribute(
                            lpAttributeList,
                            0,
                            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                            hPC,
                            sizeof(HPCON),
                            NULL,
                            NULL);
            return fSuccess ? S_OK : HRESULT_FROM_WIN32(GetLastError());
        }
        else
        {
            hr = HRESULT_FROM_WIN32(GetLastError());
        }
        return hr;
    }

    // ...

    HANDLE hOut, hIn;
    HANDLE outPipeOurSide, inPipeOurSide;
    HANDLE outPipePseudoConsoleSide, inPipePseudoConsoleSide;
    HPCON hPC = 0;

    // Create the in/out pipes:
    CreatePipe(&inPipePseudoConsoleSide, &inPipeOurSide, NULL, 0);
    CreatePipe(&outPipeOurSide, &outPipePseudoConsoleSide, NULL, 0);

    // Create the Pseudo Console, using the pipes
    CreatePseudoConsole(
        {80, 32},
        inPipePseudoConsoleSide,
        outPipePseudoConsoleSide,
        0,
        &hPC);

    // Prepare the StartupInfoEx structure attached to the ConPTY.
    STARTUPINFOEX siEx{};
    InitializeStartupInfoAttachedToConPTY(&siEx, hPC);

    // Create the client application, using startup info containing ConPTY info
    wchar_t* commandline = L"c:\\windows\\system32\\cmd.exe";
    PROCESS_INFORMATION piClient{};
    fSuccess = CreateProcessW(
                    nullptr,
                    commandline,
                    nullptr,
                    nullptr,
                    TRUE,
                    EXTENDED_STARTUPINFO_PRESENT,
                    nullptr,
                    nullptr,
                    &siEx->StartupInfo,
                    &piClient);

    // ...
```


## writing

```c
// Input "echo Hello, World!", press enter to have cmd process the command,
//  input an up arrow (to get the previous command), and enter again to execute.
std::string helloWorld = "echo Hello, World!\n\x1b[A\n";
DWORD dwWritten;
WriteFile(hIn, helloWorld.c_str(), (DWORD)helloWorld.length(), &dwWritten, nullptr);
```


## resizing

```c
// Suppose some other async callback triggered us to resize.
//      This call will update the Terminal with the size we received.
HRESULT hr = ResizePseudoConsole(hPC, {120, 30});
```