#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "forkpty.h"
#include "flutter_pty.h"

#define SESSION_INPUT_LIMIT (256 * 1024)
#define GLOBAL_INPUT_LIMIT (2 * 1024 * 1024)

typedef struct InputChunk { struct InputChunk *next; size_t length; char bytes[]; } InputChunk;
typedef struct PtyHandle {
    int master;
    pid_t pid;
    pthread_t reader, writer, waiter, closer;
    int reader_created, writer_created, waiter_created, closer_created;
    int reader_joined, writer_joined, waiter_joined, closer_joined;
    pthread_mutex_t input_lock;
    pthread_cond_t input_ready;
    sem_t output_ack;
    int startup;
    InputChunk *input_head, *input_tail;
    size_t input_bytes;
    Dart_Port output_port, exit_port;
    _Atomic int closing, close_started, reader_done, writer_done, wait_done, close_done, root_exited;
} PtyHandle;

static pthread_mutex_t global_input_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t global_input_bytes = 0;
static char error_message[256] = "";
static void set_error(const char *message) { snprintf(error_message, sizeof(error_message), "%s", message); }
static void delay_tick(void) { struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL); }
static int await_start(PtyHandle *handle) {
    pthread_mutex_lock(&handle->input_lock);
    while (handle->startup == 0) pthread_cond_wait(&handle->input_ready, &handle->input_lock);
    int ready = handle->startup == 1;
    pthread_mutex_unlock(&handle->input_lock);
    return ready;
}
static void release_global(size_t length) {
    pthread_mutex_lock(&global_input_lock); global_input_bytes -= length; pthread_mutex_unlock(&global_input_lock);
}
static void mark_closing(PtyHandle *handle) {
    pthread_mutex_lock(&handle->input_lock);
    atomic_store(&handle->closing, 1);
    pthread_cond_broadcast(&handle->input_ready);
    pthread_mutex_unlock(&handle->input_lock);
}

static void *reader_loop(void *context) {
    PtyHandle *handle = context;
    if (!await_start(handle)) return NULL;
    uint8_t buffer[4096];
    for (;;) {
        int accepted;
        do { accepted = sem_wait(&handle->output_ack); } while (accepted < 0 && errno == EINTR);
        if (accepted < 0) break;
        ssize_t length;
        for (;;) {
            struct pollfd poller = {handle->master, POLLIN, 0};
            int ready = poll(&poller, 1, 100);
            if (ready < 0 && errno != EINTR) { length = -1; break; }
            if (ready <= 0) continue;
            length = read(handle->master, buffer, sizeof(buffer));
            if (length < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            break;
        }
        if (length <= 0) break;
        Dart_CObject object = {0};
        object.type = Dart_CObject_kTypedData;
        object.value.as_typed_data.type = Dart_TypedData_kUint8;
        object.value.as_typed_data.length = length;
        object.value.as_typed_data.values = buffer;
        if (!Dart_PostCObject_DL(handle->output_port, &object)) break;
    }
    Dart_PostInteger_DL(handle->output_port, 0);
    atomic_store(&handle->reader_done, 1);
    return NULL;
}

static void *writer_loop(void *context) {
    PtyHandle *handle = context;
    if (!await_start(handle)) return NULL;
    for (;;) {
        pthread_mutex_lock(&handle->input_lock);
        while (handle->input_head == NULL && !atomic_load(&handle->closing)) pthread_cond_wait(&handle->input_ready, &handle->input_lock);
        InputChunk *chunk = handle->input_head;
        if (chunk) { handle->input_head = chunk->next; if (!handle->input_head) handle->input_tail = NULL; }
        int done = chunk == NULL && atomic_load(&handle->closing);
        pthread_mutex_unlock(&handle->input_lock);
        if (done) break;
        if (!chunk) continue;
        size_t offset = 0;
        while (offset < chunk->length && !atomic_load(&handle->closing)) {
            struct pollfd poller = {handle->master, POLLOUT, 0};
            int ready = poll(&poller, 1, 100);
            if (ready < 0 && errno != EINTR) break;
            if (ready <= 0) continue;
            ssize_t written = write(handle->master, chunk->bytes + offset, chunk->length - offset);
            if (written > 0) offset += (size_t)written;
            else if (written < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            else break;
        }
        pthread_mutex_lock(&handle->input_lock); handle->input_bytes -= chunk->length; pthread_mutex_unlock(&handle->input_lock);
        release_global(chunk->length); free(chunk);
    }
    atomic_store(&handle->writer_done, 1);
    return NULL;
}

static void *close_loop(void *context) {
    PtyHandle *handle = context;
    mark_closing(handle);
    // The waiter keeps the leader unreaped until this worker finishes, so its
    // PID cannot be recycled while we signal the owned process group.
    const int signals[] = {SIGHUP, SIGTERM, SIGKILL};
    for (int step = 0; step < 3; step++) {
        kill(-handle->pid, signals[step]);
        if (step < 2) {
            for (int tick = 0; tick < 75 && !(atomic_load(&handle->reader_done) && atomic_load(&handle->root_exited)); tick++) delay_tick();
            if (atomic_load(&handle->reader_done) && atomic_load(&handle->root_exited)) break;
        }
    }
    kill(-handle->pid, SIGKILL);
    atomic_store(&handle->close_done, 1);
    return NULL;
}

FFI_PLUGIN_EXPORT void pty_close(PtyHandle *handle) {
    if (!handle) return;
    int expected = 0;
    if (atomic_compare_exchange_strong(&handle->close_started, &expected, 1)) {
        mark_closing(handle);
        if (pthread_create(&handle->closer, NULL, close_loop, handle) == 0) handle->closer_created = 1;
        else { kill(-handle->pid, SIGKILL); atomic_store(&handle->close_done, 1); }
    }
}

static void *wait_loop(void *context) {
    PtyHandle *handle = context;
    if (!await_start(handle)) return NULL;
    siginfo_t info = {0};
    int result;
    do { result = waitid(P_PID, handle->pid, &info, WEXITED | WNOWAIT); } while (result < 0 && errno == EINTR);
    int code = result < 0 ? -1 : info.si_code == CLD_EXITED ? info.si_status : -info.si_status;
    atomic_store(&handle->root_exited, 1);
    Dart_PostInteger_DL(handle->exit_port, code);
    pty_close(handle);
    while (!atomic_load(&handle->close_done)) delay_tick();
    while (waitpid(handle->pid, NULL, 0) < 0 && errno == EINTR) {}
    atomic_store(&handle->wait_done, 1);
    return NULL;
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options) {
    if (!options || !options->arguments || !options->arguments[0]) { set_error("Invalid PTY launch options"); return NULL; }
    int errors[2] = {-1, -1};
    int mutex_ready = 0, cond_ready = 0, sem_ready = 0;
    PtyHandle *handle = calloc(1, sizeof(PtyHandle));
    if (!handle) { set_error("Failed to allocate PTY owner"); return NULL; }
    handle->master = -1;
    if (pthread_mutex_init(&handle->input_lock, NULL) != 0) goto failure;
    mutex_ready = 1;
    if (pthread_cond_init(&handle->input_ready, NULL) != 0) goto failure;
    cond_ready = 1;
    if (sem_init(&handle->output_ack, 0, 1) != 0) goto failure;
    sem_ready = 1;
    if (pipe2(errors, O_CLOEXEC) < 0) goto failure;
    struct winsize window = {.ws_row = (unsigned short)options->rows, .ws_col = (unsigned short)options->cols};
    handle->pid = pty_forkpty(&handle->master, NULL, NULL, &window);
    if (handle->pid < 0) goto failure;
    if (handle->pid == 0) {
        close(errors[0]);
        if (chdir(options->working_directory) == 0) execve(options->executable, options->arguments, options->environment);
        int error = errno;
        (void)write(errors[1], &error, sizeof(error));
        _exit(127);
    }
    close(errors[1]); errors[1] = -1;
    struct pollfd execution = {errors[0], POLLIN | POLLHUP, 0};
    int ready;
    do { ready = poll(&execution, 1, 5000); } while (ready < 0 && errno == EINTR);
    int spawn_error = 0;
    if (ready <= 0 || read(errors[0], &spawn_error, sizeof(spawn_error)) != 0) goto failure;
    close(errors[0]); errors[0] = -1;
    if (fcntl(handle->master, F_SETFL, fcntl(handle->master, F_GETFL) | O_NONBLOCK) < 0) goto failure;
    handle->output_port = options->stdout_port; handle->exit_port = options->exit_port;
    if (pthread_create(&handle->reader, NULL, reader_loop, handle) != 0) goto failure;
    handle->reader_created = 1;
    if (pthread_create(&handle->writer, NULL, writer_loop, handle) != 0) goto failure;
    handle->writer_created = 1;
    if (pthread_create(&handle->waiter, NULL, wait_loop, handle) != 0) goto failure;
    handle->waiter_created = 1;
    pthread_mutex_lock(&handle->input_lock); handle->startup = 1; pthread_cond_broadcast(&handle->input_ready); pthread_mutex_unlock(&handle->input_lock);
    return handle;
failure:
    set_error("Failed to launch PTY (executable, directory, or native resource unavailable)");
    if (handle->pid > 0) { kill(handle->pid, SIGKILL); kill(-handle->pid, SIGKILL); }
    if (mutex_ready && cond_ready) { pthread_mutex_lock(&handle->input_lock); handle->startup = -1; pthread_cond_broadcast(&handle->input_ready); pthread_mutex_unlock(&handle->input_lock); }
    if (handle->reader_created) pthread_join(handle->reader, NULL);
    if (handle->writer_created) pthread_join(handle->writer, NULL);
    if (handle->waiter_created) pthread_join(handle->waiter, NULL);
    if (handle->pid > 0) while (waitpid(handle->pid, NULL, 0) < 0 && errno == EINTR) {}
    if (handle->master >= 0) close(handle->master);
    if (errors[0] >= 0) close(errors[0]); if (errors[1] >= 0) close(errors[1]);
    if (sem_ready) sem_destroy(&handle->output_ack);
    if (cond_ready) pthread_cond_destroy(&handle->input_ready);
    if (mutex_ready) pthread_mutex_destroy(&handle->input_lock);
    free(handle); return NULL;
}

FFI_PLUGIN_EXPORT int pty_write(PtyHandle *handle, char *buffer, int length) {
    if (!handle || !buffer || length <= 0) return -1;
    if ((size_t)length > SESSION_INPUT_LIMIT || atomic_load(&handle->closing)) return 0;
    pthread_mutex_lock(&global_input_lock);
    if (global_input_bytes + (size_t)length > GLOBAL_INPUT_LIMIT) { pthread_mutex_unlock(&global_input_lock); return 0; }
    global_input_bytes += (size_t)length; pthread_mutex_unlock(&global_input_lock);
    InputChunk *chunk = malloc(sizeof(InputChunk) + (size_t)length);
    if (!chunk) { release_global((size_t)length); return 0; }
    chunk->next = NULL; chunk->length = (size_t)length; memcpy(chunk->bytes, buffer, (size_t)length);
    pthread_mutex_lock(&handle->input_lock);
    if (atomic_load(&handle->closing) || handle->input_bytes + (size_t)length > SESSION_INPUT_LIMIT) { pthread_mutex_unlock(&handle->input_lock); free(chunk); release_global((size_t)length); return 0; }
    if (handle->input_tail) handle->input_tail->next = chunk; else handle->input_head = chunk;
    handle->input_tail = chunk; handle->input_bytes += (size_t)length; pthread_cond_signal(&handle->input_ready); pthread_mutex_unlock(&handle->input_lock); return 1;
}
FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle) { if (handle) sem_post(&handle->output_ack); }
FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols) {
    if (!handle || rows < 1 || cols < 1 || rows > 32767 || cols > 32767) return -1;
    struct winsize window = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
    return ioctl(handle->master, TIOCSWINSZ, &window);
}
FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle) { return handle ? handle->pid : -1; }
FFI_PLUGIN_EXPORT char *pty_error(void) { return error_message; }

static int joined(pthread_t thread, int *complete) {
    if (!*complete) *complete = pthread_tryjoin_np(thread, NULL) == 0;
    return *complete;
}
FFI_PLUGIN_EXPORT int pty_destroy(PtyHandle *handle) {
    if (!handle) return 1;
    if (!atomic_load(&handle->wait_done) || !atomic_load(&handle->reader_done) || !atomic_load(&handle->writer_done) || !atomic_load(&handle->close_done)) return 0;
    if (!joined(handle->reader, &handle->reader_joined) || !joined(handle->writer, &handle->writer_joined) || !joined(handle->waiter, &handle->waiter_joined) || (handle->closer_created && !joined(handle->closer, &handle->closer_joined))) return 0;
    close(handle->master); sem_destroy(&handle->output_ack); pthread_cond_destroy(&handle->input_ready); pthread_mutex_destroy(&handle->input_lock);
    while (handle->input_head) { InputChunk *next = handle->input_head->next; release_global(handle->input_head->length); free(handle->input_head); handle->input_head = next; }
    free(handle); return 1;
}
