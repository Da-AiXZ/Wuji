#include "WujiISHAdapter.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define ISH_INTERNAL
#include "fs/fake.h"
#include "fs/real.h"
#include "kernel/calls.h"
#include "kernel/init.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "tools/fakefs.h"

struct bounded_stream {
    int fd;
    char *bytes;
    size_t length;
    size_t limit;
    bool eof;
    bool truncated;
};

struct WujiISHRunResult {
    struct bounded_stream stdout_stream;
    struct bounded_stream stderr_stream;
    bool root_exited;
    int raw_status;
    bool cancellation_requested;
    WujiISHCancelDelivery cancel_delivery;
    WujiISHFinalKind final_kind;
    int32_t final_value;
    char error[256];
};

static pthread_mutex_t g_boot_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exit_condition = PTHREAD_COND_INITIALIZER;
static bool g_booted = false;
static struct task *g_init_task = NULL;
static struct WujiISHRunResult *g_active_result = NULL;
static int g_active_pid = -1;

static void set_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0)
        return;
    snprintf(buffer, size, "%s", message == NULL ? "unknown error" : message);
}

static void wuji_exit_hook(struct task *task, int code) {
    pthread_mutex_lock(&g_state_lock);
    if (g_active_result != NULL && task->pid == g_active_pid) {
        g_active_result->root_exited = true;
        g_active_result->raw_status = code;
        pthread_cond_broadcast(&g_exit_condition);
    }
    pthread_mutex_unlock(&g_state_lock);
}

int wuji_ish_prepare(const char *archive_path,
                     const char *root_path,
                     char *error_buffer,
                     size_t error_buffer_size) {
    pthread_mutex_lock(&g_boot_lock);
    if (g_booted) {
        pthread_mutex_unlock(&g_boot_lock);
        return 0;
    }

    char metadata_path[4096];
    snprintf(metadata_path, sizeof(metadata_path), "%s/meta.db", root_path);
    if (access(metadata_path, F_OK) != 0) {
        struct fakefsify_error import_error = {0};
        if (!fakefs_import(archive_path, root_path, &import_error, (struct progress){0})) {
            char message[256];
            snprintf(message, sizeof(message), "rootfs import failed at line %d: %s",
                     import_error.line,
                     import_error.message == NULL ? "unknown" : import_error.message);
            set_error(error_buffer, error_buffer_size, message);
            free(import_error.message);
            pthread_mutex_unlock(&g_boot_lock);
            return -1;
        }
    }

    char data_path[4096];
    snprintf(data_path, sizeof(data_path), "%s/data", root_path);
    int error = mount_root(&fakefs, data_path);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "mount_root failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }

    error = become_first_process();
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "become_first_process failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }

    g_init_task = current;
    exit_hook = wuji_exit_hook;
    current = NULL;
    g_booted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

static bool attach_host_fd(struct task *task, int guest_fd, int host_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd == NULL)
        return false;
    fd->real_fd = host_fd;
    task->files->files[guest_fd] = fd;
    return true;
}

static void *drain_stream(void *opaque) {
    struct bounded_stream *stream = opaque;
    char chunk[4096];
    for (;;) {
        ssize_t count = read(stream->fd, chunk, sizeof(chunk));
        if (count > 0) {
            size_t remaining = stream->length < stream->limit
                ? stream->limit - stream->length
                : 0;
            size_t kept = (size_t)count < remaining ? (size_t)count : remaining;
            if (kept > 0) {
                memcpy(stream->bytes + stream->length, chunk, kept);
                stream->length += kept;
                stream->bytes[stream->length] = '\0';
            }
            if (kept < (size_t)count)
                stream->truncated = true;
            continue;
        }
        if (count == 0) {
            stream->eof = true;
            break;
        }
        if (errno == EINTR)
            continue;
        break;
    }
    close(stream->fd);
    stream->fd = -1;
    return NULL;
}

static const char *fixed_script(WujiISHSelfTestCase test_case) {
    switch (test_case) {
        case WUJI_ISH_CASE_SUCCESS:
            return "printf WUJI_STDOUT_OK; printf WUJI_STDERR_OK >&2; exit 0";
        case WUJI_ISH_CASE_NONZERO:
            return "printf WUJI_NONZERO_STDOUT; printf WUJI_NONZERO_STDERR >&2; exit 7";
        case WUJI_ISH_CASE_TRUNCATION:
            return "yes X | head -c 8192; exit 0";
        case WUJI_ISH_CASE_CANCELLATION:
            return "while :; do :; done";
    }
    return NULL;
}

static struct WujiISHRunResult *make_result(size_t output_limit) {
    struct WujiISHRunResult *result = calloc(1, sizeof(*result));
    if (result == NULL)
        return NULL;
    result->stdout_stream.limit = output_limit;
    result->stderr_stream.limit = output_limit;
    result->stdout_stream.fd = -1;
    result->stderr_stream.fd = -1;
    result->stdout_stream.bytes = calloc(output_limit + 1, 1);
    result->stderr_stream.bytes = calloc(output_limit + 1, 1);
    result->final_kind = WUJI_ISH_FINAL_UNKNOWN;
    if (result->stdout_stream.bytes == NULL || result->stderr_stream.bytes == NULL) {
        wuji_ish_result_free(result);
        return NULL;
    }
    return result;
}

WujiISHRunResult *wuji_ish_run_self_test(WujiISHSelfTestCase test_case,
                                         size_t output_limit) {
    struct WujiISHRunResult *result = make_result(output_limit);
    if (result == NULL)
        return NULL;
    const char *script = fixed_script(test_case);
    if (script == NULL || !g_booted || g_init_task == NULL) {
        set_error(result->error, sizeof(result->error), "executor is not prepared");
        return result;
    }

    pthread_mutex_lock(&g_run_lock);
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    pthread_t stdout_thread;
    pthread_t stderr_thread;
    bool stdout_reader_started = false;
    bool stderr_reader_started = false;
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        set_error(result->error, sizeof(result->error), "host pipe creation failed");
        goto finish;
    }

    struct task *saved_current = current;
    current = g_init_task;
    int error = become_new_init_child();
    if (error < 0) {
        current = saved_current;
        set_error(result->error, sizeof(result->error), "guest task creation failed");
        goto finish;
    }
    struct task *guest_task = current;

    int null_fd = open("/dev/null", O_RDONLY);
    int stdout_guest_fd = dup(stdout_pipe[1]);
    int stderr_guest_fd = dup(stderr_pipe[1]);
    if (null_fd < 0 || stdout_guest_fd < 0 || stderr_guest_fd < 0 ||
        !attach_host_fd(guest_task, 0, null_fd) ||
        !attach_host_fd(guest_task, 1, stdout_guest_fd) ||
        !attach_host_fd(guest_task, 2, stderr_guest_fd)) {
        current = saved_current;
        set_error(result->error, sizeof(result->error), "guest stdio setup failed");
        goto finish;
    }

    close(stdout_pipe[1]);
    stdout_pipe[1] = -1;
    close(stderr_pipe[1]);
    stderr_pipe[1] = -1;
    result->stdout_stream.fd = stdout_pipe[0];
    stdout_pipe[0] = -1;
    result->stderr_stream.fd = stderr_pipe[0];
    stderr_pipe[0] = -1;

    char argv[12288];
    size_t script_length = strlen(script);
    const char shell[] = "/bin/sh";
    const char option[] = "-c";
    size_t offset = 0;
    memcpy(argv + offset, shell, sizeof(shell));
    offset += sizeof(shell);
    memcpy(argv + offset, option, sizeof(option));
    offset += sizeof(option);
    memcpy(argv + offset, script, script_length + 1);
    offset += script_length + 1;
    argv[offset] = '\0';
    const char environment[] =
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "TERM=dumb\0"
        "PYTHONMALLOC=malloc\0";

    error = do_execve(shell, 3, argv, environment);
    if (error < 0) {
        current = saved_current;
        set_error(result->error, sizeof(result->error), "guest exec failed");
        goto finish;
    }

    if (pthread_create(&stdout_thread, NULL, drain_stream, &result->stdout_stream) != 0) {
        current = saved_current;
        set_error(result->error, sizeof(result->error), "stdout reader creation failed");
        goto finish;
    }
    stdout_reader_started = true;
    if (pthread_create(&stderr_thread, NULL, drain_stream, &result->stderr_stream) != 0) {
        current = saved_current;
        set_error(result->error, sizeof(result->error), "stderr reader creation failed");
        goto finish;
    }
    stderr_reader_started = true;

    pthread_mutex_lock(&g_state_lock);
    g_active_result = result;
    g_active_pid = guest_task->pid;
    pthread_mutex_unlock(&g_state_lock);

    task_start(guest_task);
    current = saved_current;

    pthread_mutex_lock(&g_state_lock);
    while (!result->root_exited)
        pthread_cond_wait(&g_exit_condition, &g_state_lock);
    pthread_mutex_unlock(&g_state_lock);

    // Completion is deliberately after both blocking readers observe EOF.
    pthread_join(stdout_thread, NULL);
    stdout_reader_started = false;
    pthread_join(stderr_thread, NULL);
    stderr_reader_started = false;

    pthread_mutex_lock(&g_state_lock);
    g_active_result = NULL;
    g_active_pid = -1;
    pthread_mutex_unlock(&g_state_lock);

    if ((result->raw_status & 0x7f) == 0) {
        result->final_kind = WUJI_ISH_FINAL_EXITED;
        result->final_value = (result->raw_status >> 8) & 0xff;
    } else {
        result->final_kind = WUJI_ISH_FINAL_SIGNALED;
        result->final_value = result->raw_status & 0x7f;
    }

finish:
    if (stdout_reader_started) {
        pthread_cancel(stdout_thread);
        pthread_join(stdout_thread, NULL);
    }
    if (stderr_reader_started) {
        pthread_cancel(stderr_thread);
        pthread_join(stderr_thread, NULL);
    }
    if (result->stdout_stream.fd >= 0) close(result->stdout_stream.fd);
    if (result->stderr_stream.fd >= 0) close(result->stderr_stream.fd);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    pthread_mutex_unlock(&g_run_lock);
    return result;
}

WujiISHCancelDelivery wuji_ish_request_cancel(void) {
    pthread_mutex_lock(&g_state_lock);
    struct WujiISHRunResult *result = g_active_result;
    int pid = g_active_pid;
    if (result != NULL)
        result->cancellation_requested = true;
    pthread_mutex_unlock(&g_state_lock);

    if (result == NULL || pid < 0)
        return WUJI_ISH_CANCEL_NO_ACTIVE_TASK;

    bool sent = false;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task != NULL) {
        send_signal(task, 9, SIGINFO_NIL);
        sent = true;
    }
    unlock(&pids_lock);

    WujiISHCancelDelivery delivery = sent
        ? WUJI_ISH_CANCEL_SIGNAL_SENT
        : WUJI_ISH_CANCEL_NO_ACTIVE_TASK;
    pthread_mutex_lock(&g_state_lock);
    if (g_active_result == result)
        result->cancel_delivery = delivery;
    pthread_mutex_unlock(&g_state_lock);
    return delivery;
}

const char *wuji_ish_result_stdout(const WujiISHRunResult *result) { return result->stdout_stream.bytes; }
const char *wuji_ish_result_stderr(const WujiISHRunResult *result) { return result->stderr_stream.bytes; }
bool wuji_ish_result_stdout_eof(const WujiISHRunResult *result) { return result->stdout_stream.eof; }
bool wuji_ish_result_stderr_eof(const WujiISHRunResult *result) { return result->stderr_stream.eof; }
bool wuji_ish_result_root_exited(const WujiISHRunResult *result) { return result->root_exited; }
bool wuji_ish_result_truncated(const WujiISHRunResult *result) {
    return result->stdout_stream.truncated || result->stderr_stream.truncated;
}
bool wuji_ish_result_cancellation_requested(const WujiISHRunResult *result) { return result->cancellation_requested; }
WujiISHCancelDelivery wuji_ish_result_cancel_delivery(const WujiISHRunResult *result) { return result->cancel_delivery; }
WujiISHFinalKind wuji_ish_result_final_kind(const WujiISHRunResult *result) { return result->final_kind; }
int32_t wuji_ish_result_final_value(const WujiISHRunResult *result) { return result->final_value; }
const char *wuji_ish_result_error(const WujiISHRunResult *result) { return result->error; }

void wuji_ish_result_free(WujiISHRunResult *result) {
    if (result == NULL)
        return;
    free(result->stdout_stream.bytes);
    free(result->stderr_stream.bytes);
    free(result);
}
