#include <Windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "flutter_pty.h"

#define SESSION_INPUT_LIMIT (256 * 1024)
#define GLOBAL_INPUT_LIMIT (2 * 1024 * 1024)
#define CLOSE_GRACE_MS 1500

typedef struct InputChunk {
    struct InputChunk *next;
    DWORD length;
    char bytes[];
} InputChunk;

typedef struct PtyHandle {
    HANDLE input;
    HANDLE output;
    HANDLE process;
    HANDLE job;
    HPCON pseudo_console;
    HANDLE reader_thread;
    HANDLE writer_thread;
    HANDLE wait_thread;
    HANDLE close_thread;
    HANDLE input_event;
    HANDLE output_ack;
    HANDLE start_event;
    CRITICAL_SECTION input_lock;
    CRITICAL_SECTION lifecycle_lock;
    InputChunk *input_head;
    InputChunk *input_tail;
    size_t input_bytes;
    DWORD process_id;
    Dart_Port output_port;
    Dart_Port exit_port;
    volatile LONG closing;
    volatile LONG close_started;
    volatile LONG reader_done;
    volatile LONG writer_done;
    volatile LONG wait_done;
    volatile LONG close_done;
    volatile LONG startup_failed;
    volatile LONG abort_input;
    bool automatic_eof;
} PtyHandle;

static volatile LONG64 global_input_bytes = 0;
static char error_message[256] = "";

static void set_error(const char *message) {
    strncpy_s(error_message, sizeof(error_message), message, _TRUNCATE);
}

static wchar_t *utf8_to_wide(const char *value) {
    if (value == NULL) return NULL;
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (length <= 0) return NULL;
    wchar_t *wide = (wchar_t *)calloc((size_t)length, sizeof(wchar_t));
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wide, length) == 0) {
        free(wide);
        return NULL;
    }
    return wide;
}

static size_t quoted_length(const wchar_t *value) {
    size_t length = 2;
    size_t slashes = 0;
    for (const wchar_t *cursor = value; *cursor; cursor++) {
        if (*cursor == L'\\') { slashes++; continue; }
        if (*cursor == L'"') length += slashes * 2 + 2;
        else length += slashes + 1;
        slashes = 0;
    }
    return length + slashes * 2 + 1;
}

static wchar_t *quote_argument(const wchar_t *value) {
    // cmd.exe parses switches directly, not through the MSCRT argv parser.
    if (*value && wcspbrk(value, L" \t\"") == NULL) return _wcsdup(value);
    size_t capacity = quoted_length(value) + 1;
    wchar_t *result = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (result == NULL) return NULL;
    size_t out = 0, slashes = 0;
    result[out++] = L'"';
    for (const wchar_t *cursor = value; *cursor; cursor++) {
        if (*cursor == L'\\') { slashes++; continue; }
        if (*cursor == L'"') {
            for (size_t i = 0; i < slashes * 2 + 1; i++) result[out++] = L'\\';
            result[out++] = L'"';
        } else {
            for (size_t i = 0; i < slashes; i++) result[out++] = L'\\';
            result[out++] = *cursor;
        }
        slashes = 0;
    }
    for (size_t i = 0; i < slashes * 2; i++) result[out++] = L'\\';
    result[out++] = L'"';
    result[out] = 0;
    return result;
}

static wchar_t *build_command(char **arguments, bool command_script) {
    size_t capacity = 1;
    for (int i = 0; arguments != NULL && arguments[i] != NULL; i++) {
        wchar_t *wide = utf8_to_wide(arguments[i]);
        if (wide == NULL) return NULL;
        capacity += quoted_length(wide) + 1;
        free(wide);
    }
    wchar_t *command = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (command == NULL) return NULL;
    for (int i = 0; arguments != NULL && arguments[i] != NULL; i++) {
        wchar_t *wide = utf8_to_wide(arguments[i]);
        wchar_t *quoted = wide == NULL ? NULL : (command_script && i == 5 ? _wcsdup(wide) : quote_argument(wide));
        free(wide);
        if (quoted == NULL) { free(command); return NULL; }
        if (i > 0) wcscat_s(command, capacity, L" ");
        wcscat_s(command, capacity, quoted);
        free(quoted);
    }
    return command;
}

static int compare_environment(const void *left, const void *right) {
    return _wcsicmp(*(const wchar_t * const *)left, *(const wchar_t * const *)right);
}

static wchar_t *build_environment(char **environment) {
    int count = 0;
    while (environment != NULL && environment[count] != NULL) count++;
    wchar_t **values = (wchar_t **)calloc((size_t)count, sizeof(wchar_t *));
    if (count > 0 && values == NULL) return NULL;
    size_t total = 1;
    for (int i = 0; i < count; i++) {
        values[i] = utf8_to_wide(environment[i]);
        if (values[i] == NULL) goto failure;
        total += wcslen(values[i]) + 1;
    }
    qsort(values, (size_t)count, sizeof(wchar_t *), compare_environment);
    wchar_t *block = (wchar_t *)calloc(total, sizeof(wchar_t));
    if (block == NULL) goto failure;
    size_t offset = 0;
    for (int i = 0; i < count; i++) {
        size_t length = wcslen(values[i]);
        memcpy(block + offset, values[i], length * sizeof(wchar_t));
        offset += length + 1;
        free(values[i]);
    }
    free(values);
    return block;
failure:
    for (int i = 0; i < count; i++) free(values[i]);
    free(values);
    return NULL;
}

static bool reserve_global(size_t length) {
    LONG64 current;
    do {
        current = InterlockedCompareExchange64(&global_input_bytes, 0, 0);
        if ((size_t)current + length > GLOBAL_INPUT_LIMIT) return false;
    } while (InterlockedCompareExchange64(&global_input_bytes, current + (LONG64)length, current) != current);
    return true;
}

static DWORD WINAPI reader_loop(LPVOID context) {
    PtyHandle *handle = (PtyHandle *)context;
    WaitForSingleObject(handle->start_event, INFINITE);
    if (handle->startup_failed) return 0;
    uint8_t buffer[4096];
    for (;;) {
        if (WaitForSingleObject(handle->output_ack, INFINITE) != WAIT_OBJECT_0) break;
        DWORD length = 0;
        if (!ReadFile(handle->output, buffer, sizeof(buffer), &length, NULL) || length == 0) break;
        Dart_CObject object = {0};
        object.type = Dart_CObject_kTypedData;
        object.value.as_typed_data.type = Dart_TypedData_kUint8;
        object.value.as_typed_data.length = length;
        object.value.as_typed_data.values = buffer;
        if (!Dart_PostCObject_DL(handle->output_port, &object)) break;
    }
    InterlockedExchange(&handle->reader_done, 1);
    Dart_PostInteger_DL(handle->output_port, 0);
    return 0;
}

static DWORD WINAPI writer_loop(LPVOID context) {
    PtyHandle *handle = (PtyHandle *)context;
    WaitForSingleObject(handle->start_event, INFINITE);
    if (handle->startup_failed) return 0;
    for (;;) {
        WaitForSingleObject(handle->input_event, INFINITE);
        for (;;) {
            EnterCriticalSection(&handle->input_lock);
            InputChunk *chunk = handle->input_head;
            if (chunk != NULL) {
                handle->input_head = chunk->next;
                if (handle->input_head == NULL) handle->input_tail = NULL;
            }
            bool done = chunk == NULL && InterlockedCompareExchange(&handle->closing, 0, 0) != 0;
            if (chunk == NULL) ResetEvent(handle->input_event);
            LeaveCriticalSection(&handle->input_lock);
            if (chunk == NULL) { if (done) { InterlockedExchange(&handle->writer_done, 1); return 0; } break; }
            DWORD offset = 0;
            while (offset < chunk->length && !handle->abort_input) {
                DWORD written = 0;
                if (!WriteFile(handle->input, chunk->bytes + offset, chunk->length - offset, &written, NULL) || written == 0) break;
                offset += written;
            }
            EnterCriticalSection(&handle->input_lock);
            handle->input_bytes -= chunk->length;
            LeaveCriticalSection(&handle->input_lock);
            InterlockedAdd64(&global_input_bytes, -(LONG64)chunk->length);
            free(chunk);
        }
    }
}

static void begin_closing(PtyHandle *handle) {
    if (InterlockedExchange(&handle->closing, 1) == 0) SetEvent(handle->input_event);
}

static DWORD WINAPI close_loop(LPVOID context) {
    PtyHandle *handle = (PtyHandle *)context;
    begin_closing(handle);
    if (handle->writer_thread != NULL && WaitForSingleObject(handle->writer_thread, 250) == WAIT_TIMEOUT) {
        InterlockedExchange(&handle->abort_input, 1);
        while (WaitForSingleObject(handle->writer_thread, 20) == WAIT_TIMEOUT) CancelSynchronousIo(handle->writer_thread);
    }
    if (handle->input != NULL) { CloseHandle(handle->input); handle->input = NULL; }
    WaitForSingleObject(handle->process, CLOSE_GRACE_MS);
    if (handle->job != NULL) {
        TerminateJobObject(handle->job, 1);
    }
    InterlockedExchange(&handle->close_done, 1);
    return 0;
}

static DWORD WINAPI wait_loop(LPVOID context) {
    PtyHandle *handle = (PtyHandle *)context;
    WaitForSingleObject(handle->start_event, INFINITE);
    if (handle->startup_failed) return 0;
    WaitForSingleObject(handle->process, INFINITE);
    DWORD exit_code = 0;
    GetExitCodeProcess(handle->process, &exit_code);
    begin_closing(handle);
    InterlockedExchange(&handle->abort_input, 1);
    while (WaitForSingleObject(handle->writer_thread, 20) == WAIT_TIMEOUT) CancelSynchronousIo(handle->writer_thread);
    // Process exit and PTY EOF are distinct. On current Windows, let ConPTY
    // flush its last frame and disconnect naturally before freeing HPCON.
    Dart_PostInteger_DL(handle->exit_port, (int32_t)exit_code);
    pty_close(handle);
    if (handle->automatic_eof) WaitForSingleObject(handle->reader_thread, INFINITE);
    EnterCriticalSection(&handle->lifecycle_lock);
    if (handle->pseudo_console != NULL) {
        ClosePseudoConsole(handle->pseudo_console);
        handle->pseudo_console = NULL;
    }
    LeaveCriticalSection(&handle->lifecycle_lock);
    InterlockedExchange(&handle->wait_done, 1);
    return 0;
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options) {
    HANDLE input_read = NULL, input_write = NULL, output_read = NULL, output_write = NULL;
    PPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    int attributes_initialized = 0;
    wchar_t *executable = NULL, *command = NULL, *environment = NULL, *working_directory = NULL;
    HPCON pseudo_console = NULL;
    PROCESS_INFORMATION process = {0};
    PtyHandle *handle = NULL;
    if (options == NULL || options->arguments == NULL || options->arguments[0] == NULL) { set_error("Invalid PTY launch options"); goto failure; }
    executable = utf8_to_wide(options->executable);
    command = build_command(options->arguments, options->windows_command_script);
    environment = build_environment(options->environment);
    working_directory = utf8_to_wide(options->working_directory);
    if (executable == NULL || command == NULL || environment == NULL || working_directory == NULL) { set_error("Invalid UTF-8 launch data"); goto failure; }
    if (!CreatePipe(&input_read, &input_write, NULL, 0) || !CreatePipe(&output_read, &output_write, NULL, 0)) { set_error("Failed to create PTY pipes"); goto failure; }
    SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);
    COORD size = {(SHORT)options->cols, (SHORT)options->rows};
    if (FAILED(CreatePseudoConsole(size, input_read, output_write, 0, &pseudo_console))) { set_error("Failed to create pseudoconsole"); goto failure; }
    CloseHandle(input_read); input_read = NULL; CloseHandle(output_write); output_write = NULL;
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
    attributes = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(bytes);
    if (attributes == NULL || !InitializeProcThreadAttributeList(attributes, 1, 0, &bytes)) { set_error("Failed to initialize pseudoconsole attributes"); goto failure; }
    attributes_initialized = 1;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pseudo_console, sizeof(pseudo_console), NULL, NULL)) { set_error("Failed to attach pseudoconsole attributes"); goto failure; }
    STARTUPINFOEXW startup = {0}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attributes;
    // Prevent CreateProcess from duplicating a redirected parent stdio handle
    // into the child. Null standard handles are connected to its ConPTY.
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    if (!CreateProcessW(executable, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, environment, working_directory, &startup.StartupInfo, &process)) { set_error("Failed to create terminal process"); goto failure; }
    handle = (PtyHandle *)calloc(1, sizeof(PtyHandle));
    if (handle == NULL) { set_error("Failed to allocate PTY owner"); goto failure; }
    handle->input = input_write; input_write = NULL; handle->output = output_read; output_read = NULL; handle->process = process.hProcess; process.hProcess = NULL; handle->process_id = process.dwProcessId; handle->pseudo_console = pseudo_console; pseudo_console = NULL; handle->output_port = options->stdout_port; handle->exit_port = options->exit_port;
    InitializeCriticalSection(&handle->input_lock);
    InitializeCriticalSection(&handle->lifecycle_lock);
    handle->input_event = CreateEventW(NULL, TRUE, FALSE, NULL); handle->output_ack = CreateSemaphoreW(NULL, 1, 1, NULL); handle->start_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    handle->job = CreateJobObjectW(NULL, NULL);
    if (handle->input_event == NULL || handle->output_ack == NULL || handle->start_event == NULL || handle->job == NULL) { set_error("Failed to allocate PTY synchronization"); goto failure; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(handle->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) { set_error("Failed to configure terminal process ownership"); goto failure; }
    if (!AssignProcessToJobObject(handle->job, handle->process)) { set_error("Failed to own terminal process tree"); goto failure; }
    typedef HRESULT (WINAPI *ReleaseConsoleFn)(HPCON);
    ReleaseConsoleFn release_console = (ReleaseConsoleFn)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "ReleasePseudoConsole");
    handle->automatic_eof = release_console != NULL && SUCCEEDED(release_console(handle->pseudo_console));
    handle->reader_thread = CreateThread(NULL, 0, reader_loop, handle, 0, NULL); handle->writer_thread = CreateThread(NULL, 0, writer_loop, handle, 0, NULL); handle->wait_thread = CreateThread(NULL, 0, wait_loop, handle, 0, NULL);
    if (handle->reader_thread == NULL || handle->writer_thread == NULL || handle->wait_thread == NULL) { set_error("Failed to start PTY workers"); goto failure; }
    if (ResumeThread(process.hThread) == (DWORD)-1) { set_error("Failed to resume terminal process"); goto failure; }
    SetEvent(handle->start_event);
    CloseHandle(process.hThread); process.hThread = NULL;
    DeleteProcThreadAttributeList(attributes); free(attributes); free(executable); free(command); free(environment); free(working_directory);
    return handle;
failure:
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) TerminateProcess(process.hProcess, 1), CloseHandle(process.hProcess);
    if (handle != NULL) {
        InterlockedExchange(&handle->startup_failed, 1);
        if (handle->process) TerminateProcess(handle->process, 1);
        if (handle->job) TerminateJobObject(handle->job, 1);
        if (handle->start_event) SetEvent(handle->start_event);
        begin_closing(handle);
        if (handle->input) { CancelIoEx(handle->input, NULL); CloseHandle(handle->input); handle->input = NULL; }
        EnterCriticalSection(&handle->lifecycle_lock);
        if (handle->pseudo_console) { ClosePseudoConsole(handle->pseudo_console); handle->pseudo_console = NULL; }
        LeaveCriticalSection(&handle->lifecycle_lock);
        if (handle->reader_thread) WaitForSingleObject(handle->reader_thread, INFINITE);
        if (handle->writer_thread) { CancelSynchronousIo(handle->writer_thread); WaitForSingleObject(handle->writer_thread, INFINITE); }
        if (handle->wait_thread) WaitForSingleObject(handle->wait_thread, INFINITE);
        if (handle->output) CloseHandle(handle->output);
        if (handle->process) CloseHandle(handle->process);
        if (handle->job) CloseHandle(handle->job);
        if (handle->reader_thread) CloseHandle(handle->reader_thread);
        if (handle->writer_thread) CloseHandle(handle->writer_thread);
        if (handle->wait_thread) CloseHandle(handle->wait_thread);
        if (handle->input_event) CloseHandle(handle->input_event);
        if (handle->output_ack) CloseHandle(handle->output_ack);
        if (handle->start_event) CloseHandle(handle->start_event);
        DeleteCriticalSection(&handle->lifecycle_lock);
        DeleteCriticalSection(&handle->input_lock);
        free(handle);
    }
    if (attributes) { if (attributes_initialized) DeleteProcThreadAttributeList(attributes); free(attributes); }
    if (pseudo_console) ClosePseudoConsole(pseudo_console);
    if (input_read) CloseHandle(input_read); if (input_write) CloseHandle(input_write); if (output_read) CloseHandle(output_read); if (output_write) CloseHandle(output_write);
    free(executable); free(command); free(environment); free(working_directory);
    return NULL;
}

FFI_PLUGIN_EXPORT int pty_write(PtyHandle *handle, char *buffer, int length) {
    if (handle == NULL || buffer == NULL || length <= 0) return -1;
    if (InterlockedCompareExchange(&handle->closing, 0, 0) != 0 || (size_t)length > SESSION_INPUT_LIMIT || !reserve_global((size_t)length)) return 0;
    InputChunk *chunk = (InputChunk *)malloc(sizeof(InputChunk) + (size_t)length);
    if (chunk == NULL) { InterlockedAdd64(&global_input_bytes, -(LONG64)length); return 0; }
    chunk->next = NULL; chunk->length = (DWORD)length; memcpy(chunk->bytes, buffer, (size_t)length);
    EnterCriticalSection(&handle->input_lock);
    if (handle->input_bytes + (size_t)length > SESSION_INPUT_LIMIT || handle->closing) { LeaveCriticalSection(&handle->input_lock); free(chunk); InterlockedAdd64(&global_input_bytes, -(LONG64)length); return 0; }
    if (handle->input_tail) handle->input_tail->next = chunk; else handle->input_head = chunk; handle->input_tail = chunk; handle->input_bytes += (size_t)length; SetEvent(handle->input_event); LeaveCriticalSection(&handle->input_lock);
    return 1;
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle) { if (handle && handle->output_ack) ReleaseSemaphore(handle->output_ack, 1, NULL); }
FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols) { if (!handle || rows < 1 || cols < 1) return -1; if (!TryEnterCriticalSection(&handle->lifecycle_lock)) return -2; int result = -1; if (handle->pseudo_console) { COORD size = {(SHORT)cols, (SHORT)rows}; result = (int)ResizePseudoConsole(handle->pseudo_console, size); } LeaveCriticalSection(&handle->lifecycle_lock); return result; }
FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle) { return handle ? (int)handle->process_id : -1; }
FFI_PLUGIN_EXPORT char *pty_error(void) { return error_message; }
FFI_PLUGIN_EXPORT void pty_close(PtyHandle *handle) {
    if (handle && InterlockedCompareExchange(&handle->close_started, 1, 0) == 0) {
        begin_closing(handle);
        handle->close_thread = CreateThread(NULL, 0, close_loop, handle, 0, NULL);
        if (!handle->close_thread) {
            InterlockedExchange(&handle->abort_input, 1);
            TerminateJobObject(handle->job, 1);
            InterlockedExchange(&handle->close_done, 1);
        }
    }
}

FFI_PLUGIN_EXPORT int pty_destroy(PtyHandle *handle) {
    if (!handle) return 1;
    if (!handle->wait_done || !handle->reader_done || !handle->writer_done || (handle->close_started && !handle->close_done)) return 0;
    // A done flag is set before a worker returns; wait for actual completion
    // without blocking Dart before freeing any memory used by that worker.
    if (WaitForSingleObject(handle->wait_thread, 0) != WAIT_OBJECT_0 || WaitForSingleObject(handle->reader_thread, 0) != WAIT_OBJECT_0 || WaitForSingleObject(handle->writer_thread, 0) != WAIT_OBJECT_0 || (handle->close_thread && WaitForSingleObject(handle->close_thread, 0) != WAIT_OBJECT_0)) return 0;
    if (handle->input) CloseHandle(handle->input); if (handle->output) CloseHandle(handle->output); if (handle->process) CloseHandle(handle->process); if (handle->job) CloseHandle(handle->job); if (handle->pseudo_console) ClosePseudoConsole(handle->pseudo_console);
    if (handle->reader_thread) CloseHandle(handle->reader_thread); if (handle->writer_thread) CloseHandle(handle->writer_thread); if (handle->wait_thread) CloseHandle(handle->wait_thread); if (handle->close_thread) CloseHandle(handle->close_thread); if (handle->input_event) CloseHandle(handle->input_event); if (handle->output_ack) CloseHandle(handle->output_ack);
    DeleteCriticalSection(&handle->input_lock);
    DeleteCriticalSection(&handle->lifecycle_lock);
    CloseHandle(handle->start_event);
    while (handle->input_head) { InputChunk *next = handle->input_head->next; InterlockedAdd64(&global_input_bytes, -(LONG64)handle->input_head->length); free(handle->input_head); handle->input_head = next; }
    free(handle);
    return 1;
}
