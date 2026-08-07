#include "WujiISHAdapter.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <resolv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define ISH_INTERNAL
#include "fs/fake.h"
#include "fs/real.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "tools/fakefs.h"

#define WUJI_PROCESS_TREE_MAX_OBSERVATIONS 11U
#define WUJI_PROCESS_TREE_OBSERVATION_INTERVAL_NS 50000000L

extern const char *uname_hostname_override;
static const char wuji_hostname_override[] = "wuji";

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
    uint64_t process_context;
    WujiISHProcessTreeKind process_tree_kind;
    int32_t initial_active_descendant_count;
    int32_t active_descendant_count;
    uint32_t process_tree_observation_count;
    bool process_tree_observed_after_terminal_barrier;
    WujiISHFixedErrorKind fixed_error_kind;
    char error[256];
};

static pthread_mutex_t g_boot_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exit_condition = PTHREAD_COND_INITIALIZER;
static bool g_booted = false;
static bool g_workspace_mounted = false;
static char g_workspace_source[4096];
static bool g_s4_workspace_mounted = false;
static char g_s4_workspace_source[4096];
static bool g_stage_b_workspace_mounted = false;
static char g_stage_b_workspace_source[4096];
static bool g_stage_c_workspace_mounted = false;
static char g_stage_c_workspace_source[4096];
static bool g_stage_d_workspace_mounted = false;
static char g_stage_d_workspace_source[4096];
static bool g_stage_d_clone_root_mounted = false;
static char g_stage_d_clone_root_source[4096];
static struct task *g_init_task = NULL;
static struct WujiISHRunResult *g_active_result = NULL;
static int g_active_pid = -1;
static uint64_t g_next_process_context = 1;
static uint64_t g_stage_d_command_attempt_count = 0;
static uint32_t g_stage_d_resolver_configuration_count = 0;

static void set_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0)
        return;
    snprintf(buffer, size, "%s", message == NULL ? "unknown error" : message);
}

static void set_run_error(struct WujiISHRunResult *result,
                          WujiISHFixedErrorKind kind,
                          const char *message) {
    if (result == NULL)
        return;
    result->fixed_error_kind = kind;
    set_error(result->error, sizeof(result->error), message);
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

bool wuji_ish_process_tree_task_state_is_active(uint64_t process_context,
                                                uint64_t task_process_context,
                                                bool zombie,
                                                bool exiting) {
    return process_context != 0 && task_process_context == process_context &&
        !zombie && !exiting;
}

static int32_t snapshot_active_process_context_tasks(uint64_t process_context) {
    int32_t active = 0;
    lock(&pids_lock);
    for (dword_t pid = 1; pid <= MAX_PID; pid++) {
        struct task *candidate = pid_get_task_zombie(pid);
        if (candidate != NULL && candidate->group != NULL &&
            wuji_ish_process_tree_task_state_is_active(
                process_context,
                candidate->group->fs_context,
                candidate->zombie,
                candidate->exiting
            ))
            active++;
    }
    unlock(&pids_lock);
    return active;
}

static void observe_process_tree_after_terminal_barrier(struct WujiISHRunResult *result) {
    if (result == NULL || result->process_context == 0 || !result->root_exited ||
        !result->stdout_stream.eof || !result->stderr_stream.eof)
        return;

    result->process_tree_observed_after_terminal_barrier = true;
    for (uint32_t index = 0; index < WUJI_PROCESS_TREE_MAX_OBSERVATIONS; index++) {
        int32_t active = snapshot_active_process_context_tasks(result->process_context);
        if (index == 0)
            result->initial_active_descendant_count = active;
        result->active_descendant_count = active;
        result->process_tree_observation_count = index + 1;
        if (active == 0)
            break;
        if (index + 1 < WUJI_PROCESS_TREE_MAX_OBSERVATIONS) {
            struct timespec interval = {
                .tv_sec = 0,
                .tv_nsec = WUJI_PROCESS_TREE_OBSERVATION_INTERVAL_NS,
            };
            nanosleep(&interval, NULL);
        }
    }
    result->process_tree_kind = result->active_descendant_count == 0
        ? WUJI_ISH_PROCESS_TREE_QUIESCENT
        : WUJI_ISH_PROCESS_TREE_DESCENDANTS_REMAIN;
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

    uname_hostname_override = wuji_hostname_override;

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

// Ported at the Wuji-owned adapter boundary from fixed ish-arm64-master AppDelegate.m.
// Only counts and byte length leave this function; resolver addresses and domains do not.
int wuji_ish_configure_stage_d_system_resolver(uint32_t *nameserver_count,
                                                uint32_t *search_domain_count,
                                                size_t *configuration_bytes,
                                                uint32_t *configuration_count,
                                                char *error_buffer,
                                                size_t error_buffer_size) {
    if (nameserver_count == NULL || search_domain_count == NULL ||
        configuration_bytes == NULL || configuration_count == NULL) {
        set_error(error_buffer, error_buffer_size, "resolver evidence missing");
        return -1;
    }
    *nameserver_count = 0;
    *search_domain_count = 0;
    *configuration_bytes = 0;
    *configuration_count = 0;

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted || g_init_task == NULL) {
        set_error(error_buffer, error_buffer_size, "executor is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }

    struct __res_state resolver = {0};
    if (res_ninit(&resolver) != 0) {
        set_error(error_buffer, error_buffer_size, "system resolver initialization failed");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }

    char content[4096] = {0};
    size_t offset = 0;
    uint32_t searches = 0;
    if (resolver.dnsrch[0] != NULL) {
        int written = snprintf(content, sizeof(content), "search");
        if (written < 0 || (size_t)written >= sizeof(content))
            goto resolver_failed;
        offset = (size_t)written;
        for (int index = 0; index <= MAXDNSRCH && resolver.dnsrch[index] != NULL; index++) {
            const char *domain = resolver.dnsrch[index];
            size_t length = strlen(domain);
            if (length == 0 || length > 253)
                goto resolver_failed;
            for (size_t byte = 0; byte < length; byte++) {
                unsigned char value = (unsigned char)domain[byte];
                if (!((value >= 'a' && value <= 'z') ||
                      (value >= 'A' && value <= 'Z') ||
                      (value >= '0' && value <= '9') || value == '-' || value == '.'))
                    goto resolver_failed;
            }
            written = snprintf(content + offset, sizeof(content) - offset, " %s", domain);
            if (written < 0 || (size_t)written >= sizeof(content) - offset)
                goto resolver_failed;
            offset += (size_t)written;
            searches++;
        }
        if (offset + 1 >= sizeof(content))
            goto resolver_failed;
        content[offset++] = '\n';
        content[offset] = '\0';
    }

    union res_sockaddr_union servers[NI_MAXSERV] = {0};
    int found = res_getservers(&resolver, servers, NI_MAXSERV);
    if (found <= 0 || found > NI_MAXSERV)
        goto resolver_failed;
    uint32_t nameservers = 0;
    for (int index = 0; index < found; index++) {
        union res_sockaddr_union server = servers[index];
        if (server.sin.sin_len == 0)
            continue;
        char address[NI_MAXHOST] = {0};
        if (getnameinfo((struct sockaddr *)&server.sin, server.sin.sin_len,
                        address, sizeof(address), NULL, 0, NI_NUMERICHOST) != 0)
            goto resolver_failed;
        int written = snprintf(content + offset, sizeof(content) - offset,
                               "nameserver %s\n", address);
        if (written < 0 || (size_t)written >= sizeof(content) - offset)
            goto resolver_failed;
        offset += (size_t)written;
        nameservers++;
    }
    if (nameservers == 0)
        goto resolver_failed;

    pthread_mutex_lock(&g_run_lock);
    current = g_init_task;
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd)) {
        current = NULL;
        set_error(error_buffer, error_buffer_size, "guest resolver open failed");
        res_nclose(&resolver);
        pthread_mutex_unlock(&g_run_lock);
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    size_t persisted = 0;
    while (persisted < offset) {
        ssize_t count = fd->ops->write(fd, content + persisted, offset - persisted);
        if (count <= 0) {
            fd_close(fd);
            current = NULL;
            set_error(error_buffer, error_buffer_size, "guest resolver write failed");
            res_nclose(&resolver);
            pthread_mutex_unlock(&g_run_lock);
            pthread_mutex_unlock(&g_boot_lock);
            return -1;
        }
        persisted += (size_t)count;
    }
    fd_close(fd);
    current = NULL;
    res_nclose(&resolver);
    pthread_mutex_unlock(&g_run_lock);

    if (g_stage_d_resolver_configuration_count != UINT32_MAX)
        g_stage_d_resolver_configuration_count++;
    *nameserver_count = nameservers;
    *search_domain_count = searches;
    *configuration_bytes = offset;
    *configuration_count = g_stage_d_resolver_configuration_count;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;

resolver_failed:
    set_error(error_buffer, error_buffer_size, "system resolver state is invalid or exceeds bounds");
    res_nclose(&resolver);
    pthread_mutex_unlock(&g_boot_lock);
    return -1;
}

uint64_t wuji_ish_stage_d_command_attempt_count(void) {
    pthread_mutex_lock(&g_state_lock);
    uint64_t count = g_stage_d_command_attempt_count;
    pthread_mutex_unlock(&g_state_lock);
    return count;
}

int wuji_ish_mount_read_only_workspace(const char *host_path,
                                       char *error_buffer,
                                       size_t error_buffer_size) {
    if (host_path == NULL || host_path[0] == '\0') {
        set_error(error_buffer, error_buffer_size, "workspace path missing");
        return -1;
    }
    char canonical_path[sizeof(g_workspace_source)];
    if (realpath(host_path, canonical_path) == NULL) {
        set_error(error_buffer, error_buffer_size, "workspace path unavailable");
        return -1;
    }
    struct stat workspace_stat;
    if (stat(canonical_path, &workspace_stat) != 0 || !S_ISDIR(workspace_stat.st_mode)) {
        set_error(error_buffer, error_buffer_size, "workspace path is not a directory");
        return -1;
    }

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted) {
        set_error(error_buffer, error_buffer_size, "executor is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    if (g_workspace_mounted) {
        bool same_source = strcmp(g_workspace_source, canonical_path) == 0;
        if (!same_source)
            set_error(error_buffer, error_buffer_size, "different workspace already mounted");
        pthread_mutex_unlock(&g_boot_lock);
        return same_source ? 0 : -1;
    }

    int flags = MS_READONLY_ | MS_NOSUID_ | MS_NODEV_ | MS_NOEXEC_;
    int error = do_mount(&realfs, canonical_path, "/wuji-s3", "", flags);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "workspace mount failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }
    snprintf(g_workspace_source, sizeof(g_workspace_source), "%s", canonical_path);
    g_workspace_mounted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

int wuji_ish_mount_s4_workspace(const char *host_path,
                                char *error_buffer,
                                size_t error_buffer_size) {
    if (host_path == NULL || host_path[0] == '\0') {
        set_error(error_buffer, error_buffer_size, "S4 workspace path missing");
        return -1;
    }
    char canonical_path[sizeof(g_s4_workspace_source)];
    if (realpath(host_path, canonical_path) == NULL) {
        set_error(error_buffer, error_buffer_size, "S4 workspace path unavailable");
        return -1;
    }
    struct stat workspace_stat;
    if (stat(canonical_path, &workspace_stat) != 0 || !S_ISDIR(workspace_stat.st_mode)) {
        set_error(error_buffer, error_buffer_size, "S4 workspace path is not a directory");
        return -1;
    }

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted) {
        set_error(error_buffer, error_buffer_size, "executor is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    if (g_s4_workspace_mounted) {
        bool same_source = strcmp(g_s4_workspace_source, canonical_path) == 0;
        if (!same_source)
            set_error(error_buffer, error_buffer_size, "different S4 workspace already mounted");
        pthread_mutex_unlock(&g_boot_lock);
        return same_source ? 0 : -1;
    }

    int flags = MS_NOSUID_ | MS_NODEV_ | MS_NOEXEC_;
    int error = do_mount(&realfs, canonical_path, "/wuji-s4", "", flags);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "S4 workspace mount failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }
    snprintf(g_s4_workspace_source, sizeof(g_s4_workspace_source), "%s", canonical_path);
    g_s4_workspace_mounted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

int wuji_ish_mount_stage_b_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size) {
    if (host_path == NULL || host_path[0] == '\0') {
        set_error(error_buffer, error_buffer_size, "invalid Stage B workspace path");
        return -1;
    }
    char canonical_path[sizeof(g_stage_b_workspace_source)];
    if (realpath(host_path, canonical_path) == NULL) {
        set_error(error_buffer, error_buffer_size, "Stage B workspace canonicalization failed");
        return -1;
    }
    struct stat status;
    if (lstat(canonical_path, &status) != 0 || !S_ISDIR(status.st_mode)) {
        set_error(error_buffer, error_buffer_size, "Stage B workspace is unavailable");
        return -1;
    }

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted) {
        set_error(error_buffer, error_buffer_size, "iSH is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    if (g_stage_b_workspace_mounted) {
        bool same_source = strcmp(g_stage_b_workspace_source, canonical_path) == 0;
        if (!same_source)
            set_error(error_buffer, error_buffer_size, "different Stage B workspace already mounted");
        pthread_mutex_unlock(&g_boot_lock);
        return same_source ? 0 : -1;
    }

    int flags = MS_READONLY_ | MS_NOSUID_ | MS_NODEV_ | MS_NOEXEC_;
    int error = do_mount(&realfs, canonical_path, "/wuji-stage-b", "", flags);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "Stage B workspace mount failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }
    snprintf(g_stage_b_workspace_source, sizeof(g_stage_b_workspace_source), "%s", canonical_path);
    g_stage_b_workspace_mounted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

int wuji_ish_mount_stage_c_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size) {
    if (host_path == NULL || host_path[0] == '\0') {
        set_error(error_buffer, error_buffer_size, "invalid Stage C workspace path");
        return -1;
    }
    char canonical_path[sizeof(g_stage_c_workspace_source)];
    if (realpath(host_path, canonical_path) == NULL) {
        set_error(error_buffer, error_buffer_size, "Stage C workspace canonicalization failed");
        return -1;
    }
    struct stat info;
    if (stat(canonical_path, &info) < 0 || !S_ISDIR(info.st_mode)) {
        set_error(error_buffer, error_buffer_size, "Stage C workspace is unavailable");
        return -1;
    }

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted) {
        set_error(error_buffer, error_buffer_size, "iSH is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    if (g_stage_c_workspace_mounted) {
        bool same_source = strcmp(g_stage_c_workspace_source, canonical_path) == 0;
        if (!same_source)
            set_error(error_buffer, error_buffer_size, "different Stage C workspace already mounted");
        pthread_mutex_unlock(&g_boot_lock);
        return same_source ? 0 : -1;
    }

    int flags = MS_NOSUID_ | MS_NODEV_ | MS_NOEXEC_;
    int error = do_mount(&realfs, canonical_path, "/wuji-stage-c", "", flags);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "Stage C workspace mount failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }
    snprintf(g_stage_c_workspace_source, sizeof(g_stage_c_workspace_source), "%s", canonical_path);
    g_stage_c_workspace_mounted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

static int mount_stage_d_root(const char *host_path,
                              const char *guest_path,
                              bool *mounted,
                              char *mounted_source,
                              size_t mounted_source_size,
                              char *error_buffer,
                              size_t error_buffer_size) {
    if (host_path == NULL || host_path[0] == '\0') {
        set_error(error_buffer, error_buffer_size, "invalid Stage D root path");
        return -1;
    }
    char canonical_path[4096];
    if (realpath(host_path, canonical_path) == NULL) {
        set_error(error_buffer, error_buffer_size, "Stage D root canonicalization failed");
        return -1;
    }
    struct stat info;
    if (lstat(canonical_path, &info) != 0 || !S_ISDIR(info.st_mode)) {
        set_error(error_buffer, error_buffer_size, "Stage D root is unavailable");
        return -1;
    }

    pthread_mutex_lock(&g_boot_lock);
    if (!g_booted) {
        set_error(error_buffer, error_buffer_size, "iSH is not prepared");
        pthread_mutex_unlock(&g_boot_lock);
        return -1;
    }
    if (*mounted) {
        bool same_source = strcmp(mounted_source, canonical_path) == 0;
        if (!same_source)
            set_error(error_buffer, error_buffer_size, "different Stage D root already mounted");
        pthread_mutex_unlock(&g_boot_lock);
        return same_source ? 0 : -1;
    }

    int flags = MS_NOSUID_ | MS_NODEV_ | MS_NOEXEC_;
    int error = do_mount(&realfs, canonical_path, guest_path, "", flags);
    if (error < 0) {
        set_error(error_buffer, error_buffer_size, "Stage D root mount failed");
        pthread_mutex_unlock(&g_boot_lock);
        return error;
    }
    snprintf(mounted_source, mounted_source_size, "%s", canonical_path);
    *mounted = true;
    pthread_mutex_unlock(&g_boot_lock);
    return 0;
}

int wuji_ish_mount_stage_d_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size) {
    return mount_stage_d_root(host_path, "/wuji-stage-d", &g_stage_d_workspace_mounted,
                              g_stage_d_workspace_source, sizeof(g_stage_d_workspace_source),
                              error_buffer, error_buffer_size);
}

int wuji_ish_mount_stage_d_clone_root(const char *host_path,
                                      char *error_buffer,
                                      size_t error_buffer_size) {
    return mount_stage_d_root(host_path, "/wuji-stage-d-clones", &g_stage_d_clone_root_mounted,
                              g_stage_d_clone_root_source, sizeof(g_stage_d_clone_root_source),
                              error_buffer, error_buffer_size);
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
        case WUJI_ISH_CASE_PROCESS_TREE_TRANSIENT_NONZERO:
        case WUJI_ISH_CASE_PROCESS_TREE_PERSISTENT_NONZERO:
        case WUJI_ISH_CASE_PROCESS_TREE_CONTEXT_CLEAN:
            return NULL;
    }
    return NULL;
}

static bool append_argument(char *buffer,
                            size_t capacity,
                            size_t *offset,
                            const char *argument) {
    size_t length = strlen(argument) + 1;
    if (*offset >= capacity || length > capacity - *offset - 1)
        return false;
    memcpy(buffer + *offset, argument, length);
    *offset += length;
    buffer[*offset] = '\0';
    return true;
}

static bool valid_relative_path_with_limit(const char *path, size_t maximum_length) {
    if (path == NULL)
        return false;
    size_t length = strlen(path);
    if (length > maximum_length || path[0] == '/' || path[0] == '\\')
        return false;
    if (strchr(path, '\\') != NULL || strchr(path, '%') != NULL)
        return false;

    const char *component = path;
    while (*component != '\0') {
        const char *slash = strchr(component, '/');
        size_t component_length = slash == NULL
            ? strlen(component)
            : (size_t)(slash - component);
        if (component_length == 0 ||
            (component_length == 1 && component[0] == '.') ||
            (component_length == 2 && component[0] == '.' && component[1] == '.'))
            return false;
        for (size_t index = 0; index < component_length; index++) {
            unsigned char byte = (unsigned char)component[index];
            if (byte < 0x20 || byte == 0x7f)
                return false;
        }
        if (slash == NULL)
            break;
        component = slash + 1;
    }
    return true;
}

static bool valid_relative_path(const char *path) {
    return valid_relative_path_with_limit(path, 512);
}

static bool build_guest_path(const char *relative_path, char *output, size_t output_size) {
    if (!valid_relative_path(relative_path))
        return false;
    int count = relative_path[0] == '\0'
        ? snprintf(output, output_size, "/wuji-s3")
        : snprintf(output, output_size, "/wuji-s3/%s", relative_path);
    return count > 0 && (size_t)count < output_size;
}

static bool build_s4_guest_path(const char *relative_path, char *output, size_t output_size) {
    if (!valid_relative_path(relative_path))
        return false;
    int count = relative_path[0] == '\0'
        ? snprintf(output, output_size, "/wuji-s4")
        : snprintf(output, output_size, "/wuji-s4/%s", relative_path);
    return count > 0 && (size_t)count < output_size;
}

static bool build_stage_b_guest_path(const char *relative_path, char *output, size_t output_size) {
    if (!valid_relative_path_with_limit(relative_path, 1024))
        return false;
    int count = relative_path[0] == '\0'
        ? snprintf(output, output_size, "/wuji-stage-b")
        : snprintf(output, output_size, "/wuji-stage-b/%s", relative_path);
    return count > 0 && (size_t)count < output_size;
}

static bool build_stage_c_guest_path(const char *relative_path, char *output, size_t output_size) {
    if (!valid_relative_path_with_limit(relative_path, 1024))
        return false;
    int count = relative_path[0] == '\0'
        ? snprintf(output, output_size, "/wuji-stage-c")
        : snprintf(output, output_size, "/wuji-stage-c/%s", relative_path);
    return count > 0 && (size_t)count < output_size;
}

static bool valid_query(const char *query, size_t maximum_length) {
    if (query == NULL)
        return false;
    size_t length = strlen(query);
    if (length == 0 || length > maximum_length)
        return false;
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)query[index];
        if (byte < 0x20 || byte == 0x7f)
            return false;
    }
    return true;
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
    result->fixed_error_kind = WUJI_ISH_FIXED_ERROR_NONE;
    if (result->stdout_stream.bytes == NULL || result->stderr_stream.bytes == NULL) {
        wuji_ish_result_free(result);
        return NULL;
    }
    return result;
}

static WujiISHRunResult *run_arguments_in_directory(const char *executable,
                                                    int argument_count,
                                                    char *arguments,
                                                    size_t output_limit,
                                                    const char *guest_cwd,
                                                    bool observe_process_tree) {
    struct WujiISHRunResult *result = make_result(output_limit);
    if (result == NULL)
        return NULL;
    if (executable == NULL || arguments == NULL || argument_count <= 0 ||
        !g_booted || g_init_task == NULL) {
        set_run_error(result, WUJI_ISH_FIXED_ERROR_NOT_PREPARED, "executor is not prepared");
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
        set_run_error(result, WUJI_ISH_FIXED_ERROR_HOST_PIPE, "host pipe creation failed");
        goto finish;
    }

    struct task *saved_current = current;
    current = g_init_task;
    int error = become_new_init_child();
    if (error < 0) {
        current = saved_current;
        set_run_error(result, WUJI_ISH_FIXED_ERROR_GUEST_TASK, "guest task creation failed");
        goto finish;
    }
    struct task *guest_task = current;

    if (observe_process_tree) {
        pthread_mutex_lock(&g_state_lock);
        uint64_t context = g_next_process_context++;
        if (context == 0)
            context = g_next_process_context++;
        result->process_context = context;
        pthread_mutex_unlock(&g_state_lock);
        lock(&pids_lock);
        guest_task->group->fs_context = context;
        unlock(&pids_lock);
    }

    if (guest_cwd != NULL) {
        struct fd *cwd = generic_open(guest_cwd, O_RDONLY_, 0);
        if (IS_ERR(cwd)) {
            current = saved_current;
            set_run_error(result, WUJI_ISH_FIXED_ERROR_GUEST_CWD, "guest cwd unavailable");
            goto finish;
        }
        fs_chdir(guest_task->fs, cwd);
    }

    int null_fd = open("/dev/null", O_RDONLY);
    int stdout_guest_fd = dup(stdout_pipe[1]);
    int stderr_guest_fd = dup(stderr_pipe[1]);
    if (null_fd < 0 || stdout_guest_fd < 0 || stderr_guest_fd < 0 ||
        !attach_host_fd(guest_task, 0, null_fd) ||
        !attach_host_fd(guest_task, 1, stdout_guest_fd) ||
        !attach_host_fd(guest_task, 2, stderr_guest_fd)) {
        current = saved_current;
        set_run_error(result, WUJI_ISH_FIXED_ERROR_GUEST_STDIO, "guest stdio setup failed");
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

    const char environment[] =
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "TERM=dumb\0"
        "PYTHONMALLOC=malloc\0"
        "GIT_TERMINAL_PROMPT=0\0"
        "GIT_ASKPASS=/bin/false\0"
        "SSH_ASKPASS=/bin/false\0";

    error = do_execve(executable, argument_count, arguments, environment);
    if (error < 0) {
        current = saved_current;
        set_run_error(result, WUJI_ISH_FIXED_ERROR_GUEST_EXEC, "guest exec failed");
        goto finish;
    }

    if (pthread_create(&stdout_thread, NULL, drain_stream, &result->stdout_stream) != 0) {
        current = saved_current;
        set_run_error(result, WUJI_ISH_FIXED_ERROR_STDOUT_READER, "stdout reader creation failed");
        goto finish;
    }
    stdout_reader_started = true;
    if (pthread_create(&stderr_thread, NULL, drain_stream, &result->stderr_stream) != 0) {
        current = saved_current;
        set_run_error(result, WUJI_ISH_FIXED_ERROR_STDERR_READER, "stderr reader creation failed");
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

    observe_process_tree_after_terminal_barrier(result);

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

static WujiISHRunResult *run_arguments(const char *executable,
                                       int argument_count,
                                       char *arguments,
                                       size_t output_limit) {
    return run_arguments_in_directory(
        executable, argument_count, arguments, output_limit, NULL, false
    );
}

struct process_tree_test_task {
    struct task *task;
    struct tgroup *group;
};

struct process_tree_test_release {
    struct task *task;
};

static bool make_process_tree_test_task(uint64_t process_context,
                                        bool zombie,
                                        bool exiting,
                                        struct process_tree_test_task *test_task) {
    struct tgroup *group = calloc(1, sizeof(*group));
    if (group == NULL)
        return false;
    struct task *task = task_create_(g_init_task);
    if (task == NULL) {
        free(group);
        return false;
    }
    group->fs_context = process_context;
    lock(&pids_lock);
    task->group = group;
    task->zombie = zombie;
    task->exiting = exiting;
    unlock(&pids_lock);
    test_task->task = task;
    test_task->group = group;
    return true;
}

static void destroy_process_tree_test_task(struct process_tree_test_task *test_task) {
    if (test_task->task != NULL) {
        lock(&pids_lock);
        struct task *listed = pid_get_task_zombie(test_task->task->pid);
        if (listed == test_task->task)
            task_destroy(test_task->task);
        unlock(&pids_lock);
    }
    free(test_task->group);
    *test_task = (struct process_tree_test_task) {};
}

static void *release_process_tree_test_task(void *context) {
    struct process_tree_test_release *release = context;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 200000000L};
    nanosleep(&delay, NULL);
    lock(&pids_lock);
    struct task *listed = pid_get_task_zombie(release->task->pid);
    if (listed == release->task)
        listed->exiting = true;
    unlock(&pids_lock);
    return NULL;
}

static WujiISHRunResult *run_process_tree_self_test(WujiISHSelfTestCase test_case,
                                                     size_t output_limit) {
    struct WujiISHRunResult *result = make_result(output_limit);
    if (result == NULL)
        return NULL;
    if (!g_booted || g_init_task == NULL) {
        set_run_error(result, WUJI_ISH_FIXED_ERROR_NOT_PREPARED, "executor is not prepared");
        return result;
    }
    static const char marker[] = "WUJI_TREE_NONZERO";
    if (output_limit < sizeof(marker) - 1) {
        set_run_error(result, WUJI_ISH_FIXED_ERROR_INVALID_INPUT, "output limit unavailable");
        return result;
    }

    memcpy(result->stderr_stream.bytes, marker, sizeof(marker));
    result->stderr_stream.length = sizeof(marker) - 1;
    result->root_exited = true;
    result->raw_status = 128 << 8;
    result->final_kind = WUJI_ISH_FINAL_EXITED;
    result->final_value = 128;
    result->stdout_stream.eof = true;
    result->stderr_stream.eof = true;

    const uint64_t process_context = UINT64_MAX - 1024;
    uint64_t task_process_context = process_context;
    if (test_case == WUJI_ISH_CASE_PROCESS_TREE_CONTEXT_CLEAN)
        task_process_context++;
    result->process_context = process_context;

    pthread_mutex_lock(&g_run_lock);
    struct process_tree_test_task test_task = {0};
    if (!make_process_tree_test_task(task_process_context, false, false, &test_task)) {
        set_run_error(result, WUJI_ISH_FIXED_ERROR_INTERNAL, "process-tree test task unavailable");
        goto finish;
    }

    pthread_t release_thread;
    bool release_started = false;
    struct process_tree_test_release release = {.task = test_task.task};
    if (test_case == WUJI_ISH_CASE_PROCESS_TREE_TRANSIENT_NONZERO) {
        if (pthread_create(
                &release_thread, NULL, release_process_tree_test_task, &release
            ) != 0) {
            set_run_error(result, WUJI_ISH_FIXED_ERROR_INTERNAL,
                          "process-tree release unavailable");
            goto finish;
        }
        release_started = true;
    }

    observe_process_tree_after_terminal_barrier(result);
    if (release_started)
        pthread_join(release_thread, NULL);

finish:
    destroy_process_tree_test_task(&test_task);
    pthread_mutex_unlock(&g_run_lock);
    return result;
}

WujiISHRunResult *wuji_ish_run_self_test(WujiISHSelfTestCase test_case,
                                         size_t output_limit) {
    if (test_case == WUJI_ISH_CASE_PROCESS_TREE_TRANSIENT_NONZERO ||
        test_case == WUJI_ISH_CASE_PROCESS_TREE_PERSISTENT_NONZERO ||
        test_case == WUJI_ISH_CASE_PROCESS_TREE_CONTEXT_CLEAN)
        return run_process_tree_self_test(test_case, output_limit);
    const char *script = fixed_script(test_case);
    if (script == NULL)
        return NULL;
    char arguments[12288] = {0};
    size_t offset = 0;
    if (!append_argument(arguments, sizeof(arguments), &offset, "/bin/sh") ||
        !append_argument(arguments, sizeof(arguments), &offset, "-c") ||
        !append_argument(arguments, sizeof(arguments), &offset, script))
        return NULL;
    return run_arguments_in_directory(
        "/bin/sh", 3, arguments, output_limit, NULL, false
    );
}

static WujiISHRunResult *run_read_only_operation(WujiISHReadOnlyOperation operation,
                                                 const char *relative_path,
                                                 const char *query,
                                                 size_t output_limit,
                                                 bool mounted,
                                                 int workspace_kind) {
    size_t maximum_output = workspace_kind == 2 ? 32768 : 4096;
    if (!mounted || output_limit == 0 || output_limit > maximum_output)
        return NULL;

    char guest_path[2048];
    bool valid_path = workspace_kind == 2
        ? build_stage_b_guest_path(relative_path, guest_path, sizeof(guest_path))
        : workspace_kind == 1
            ? build_s4_guest_path(relative_path, guest_path, sizeof(guest_path))
            : build_guest_path(relative_path, guest_path, sizeof(guest_path));
    if (!valid_path)
        return NULL;

    char arguments[4096] = {0};
    size_t offset = 0;
    const char *executable = NULL;
    int argument_count = 0;
    switch (operation) {
        case WUJI_ISH_READ_ONLY_LIST:
            executable = "/bin/ls";
            argument_count = 4;
            if (!append_argument(arguments, sizeof(arguments), &offset, executable) ||
                !append_argument(arguments, sizeof(arguments), &offset, "-1A") ||
                !append_argument(arguments, sizeof(arguments), &offset, "--") ||
                !append_argument(arguments, sizeof(arguments), &offset, guest_path))
                return NULL;
            break;
        case WUJI_ISH_READ_ONLY_SEARCH:
            if (!valid_query(query, workspace_kind == 2 ? 512 : 256))
                return NULL;
            if (workspace_kind == 2) {
                executable = "/bin/busybox";
                argument_count = 18;
                if (!append_argument(arguments, sizeof(arguments), &offset, executable) ||
                    !append_argument(arguments, sizeof(arguments), &offset, "find") ||
                    !append_argument(arguments, sizeof(arguments), &offset, guest_path) ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-path") ||
                    !append_argument(arguments, sizeof(arguments), &offset,
                                     "/wuji-stage-b/.wuji-stage-a-workspace.json") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-prune") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-o") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-type") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "f") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-exec") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "/bin/grep") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-n") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-F") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-H") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "--") ||
                    !append_argument(arguments, sizeof(arguments), &offset, query) ||
                    !append_argument(arguments, sizeof(arguments), &offset, "{}") ||
                    !append_argument(arguments, sizeof(arguments), &offset, ";"))
                    return NULL;
            } else {
                executable = "/bin/grep";
                argument_count = 8;
                if (!append_argument(arguments, sizeof(arguments), &offset, executable) ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-r") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-n") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-F") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "-H") ||
                    !append_argument(arguments, sizeof(arguments), &offset, "--") ||
                    !append_argument(arguments, sizeof(arguments), &offset, query) ||
                    !append_argument(arguments, sizeof(arguments), &offset, guest_path))
                    return NULL;
            }
            break;
        case WUJI_ISH_READ_ONLY_READ:
            executable = "/bin/cat";
            argument_count = 3;
            if (!append_argument(arguments, sizeof(arguments), &offset, executable) ||
                !append_argument(arguments, sizeof(arguments), &offset, "--") ||
                !append_argument(arguments, sizeof(arguments), &offset, guest_path))
                return NULL;
            break;
        default:
            return NULL;
    }
    return run_arguments(executable, argument_count, arguments, output_limit);
}

WujiISHRunResult *wuji_ish_run_read_only(WujiISHReadOnlyOperation operation,
                                         const char *relative_path,
                                         const char *query,
                                         size_t output_limit) {
    return run_read_only_operation(
        operation,
        relative_path,
        query,
        output_limit,
        g_workspace_mounted,
        0
    );
}

WujiISHRunResult *wuji_ish_run_s4_read_only(WujiISHReadOnlyOperation operation,
                                            const char *relative_path,
                                            const char *query,
                                            size_t output_limit) {
    return run_read_only_operation(
        operation,
        relative_path,
        query,
        output_limit,
        g_s4_workspace_mounted,
        1
    );
}

WujiISHRunResult *wuji_ish_run_stage_b_read_only(WujiISHReadOnlyOperation operation,
                                                  const char *relative_path,
                                                  const char *query,
                                                  size_t output_limit) {
    return run_read_only_operation(
        operation,
        relative_path,
        query,
        output_limit,
        g_stage_b_workspace_mounted,
        2
    );
}

static const char stage_c_edit_script[] =
    "set -eu\n"
    "p=$1\n"
    "old=$2\n"
    "new=$3\n"
    "before=$4\n"
    "after=$5\n"
    "tmp=${p}.wuji-stage-c-tmp\n"
    "[ -f \"$p\" ] && [ ! -L \"$p\" ] || exit 60\n"
    "actual=$(sha256sum \"$p\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$before\" ] || exit 61\n"
    "[ ! -e \"$tmp\" ] || exit 62\n"
    "trap 'rm -f -- \"$tmp\"' 0 1 2 15\n"
    "awk -v old=\"$old\" -v new=\"$new\" 'BEGIN { count=0 } { if ($0 == old) { count++; print new } else { print } } END { if (count != 1) exit 63 }' \"$p\" > \"$tmp\"\n"
    "actual=$(sha256sum \"$tmp\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$after\" ] || exit 64\n"
    "mv -f -- \"$tmp\" \"$p\"\n"
    "trap - 0 1 2 15\n"
    "actual=$(sha256sum \"$p\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$after\" ] || exit 65\n"
    "printf 'WUJI_STAGE_C_EDIT_OK\\n'\n";

static bool valid_sha256(const char *value);

static bool stage_c_path_has_git_component(const char *path) {
    const char *component = path;
    while (component != NULL && *component != '\0') {
        const char *separator = strchr(component, '/');
        size_t length = separator == NULL
            ? strlen(component)
            : (size_t)(separator - component);
        if (length == 4 && component[0] == '.' &&
            (component[1] == 'g' || component[1] == 'G') &&
            (component[2] == 'i' || component[2] == 'I') &&
            (component[3] == 't' || component[3] == 'T'))
            return true;
        component = separator == NULL ? NULL : separator + 1;
    }
    return false;
}

WujiISHRunResult *wuji_ish_run_stage_c_edit(const char *relative_path,
                                            const char *expected_old,
                                            const char *replacement,
                                            const char *before_sha256,
                                            const char *after_sha256,
                                            size_t output_limit) {
    if (!g_stage_c_workspace_mounted || output_limit == 0 || output_limit > 32768 ||
        relative_path == NULL || expected_old == NULL || replacement == NULL ||
        !valid_sha256(before_sha256) || !valid_sha256(after_sha256) ||
        strcasecmp(relative_path, ".wuji-stage-a-workspace.json") == 0 ||
        stage_c_path_has_git_component(relative_path) ||
        strchr(expected_old, '\\') != NULL || strchr(replacement, '\\') != NULL ||
        strchr(expected_old, '\n') != NULL || strchr(replacement, '\n') != NULL ||
        strchr(expected_old, '\r') != NULL || strchr(replacement, '\r') != NULL)
        return NULL;

    char guest_path[2048];
    if (!build_stage_c_guest_path(relative_path, guest_path, sizeof(guest_path)))
        return NULL;
    char arguments[12288] = {0};
    size_t offset = 0;
    if (!append_argument(arguments, sizeof(arguments), &offset, "/bin/sh") ||
        !append_argument(arguments, sizeof(arguments), &offset, "-c") ||
        !append_argument(arguments, sizeof(arguments), &offset, stage_c_edit_script) ||
        !append_argument(arguments, sizeof(arguments), &offset, "wuji-stage-c-edit") ||
        !append_argument(arguments, sizeof(arguments), &offset, guest_path) ||
        !append_argument(arguments, sizeof(arguments), &offset, expected_old) ||
        !append_argument(arguments, sizeof(arguments), &offset, replacement) ||
        !append_argument(arguments, sizeof(arguments), &offset, before_sha256) ||
        !append_argument(arguments, sizeof(arguments), &offset, after_sha256))
        return NULL;
    return run_arguments("/bin/sh", 9, arguments, output_limit);
}

static const char *stage_d_executable_path(const char *executable) {
    if (executable == NULL)
        return NULL;
    if (strcmp(executable, "pwd") == 0) return "/bin/pwd";
    if (strcmp(executable, "ls") == 0) return "/bin/ls";
    if (strcmp(executable, "cat") == 0) return "/bin/cat";
    if (strcmp(executable, "sed") == 0) return "/bin/sed";
    if (strcmp(executable, "rm") == 0) return "/bin/rm";
    if (strcmp(executable, "cp") == 0) return "/bin/cp";
    if (strcmp(executable, "mv") == 0) return "/bin/mv";
    if (strcmp(executable, "git") == 0) return "/usr/bin/git";
    if (strcmp(executable, "python3") == 0) return "/usr/bin/python3";
    if (strcmp(executable, "node") == 0) return "/usr/bin/node";
    if (strcmp(executable, "npm") == 0) return "/usr/bin/npm";
    if (strcmp(executable, "apk") == 0) return "/sbin/apk";
    return NULL;
}

static bool valid_stage_d_argument(const char *argument, size_t length) {
    if (argument == NULL || length == 0 || length > 1024)
        return false;
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)argument[index];
        if (byte < 0x20 || byte == 0x7f)
            return false;
    }
    return true;
}

static bool build_stage_d_cwd(const char *relative_cwd,
                              WujiISHStageDRoot root,
                              char *output,
                              size_t output_size) {
    if (relative_cwd == NULL || !valid_relative_path_with_limit(relative_cwd, 1024))
        return false;
    const char *base = NULL;
    switch (root) {
        case WUJI_ISH_STAGE_D_WORKSPACE:
            if (!g_stage_d_workspace_mounted) return false;
            base = "/wuji-stage-d";
            break;
        case WUJI_ISH_STAGE_D_CLONE_ROOT:
            if (!g_stage_d_clone_root_mounted) return false;
            base = "/wuji-stage-d-clones";
            break;
        case WUJI_ISH_STAGE_D_ROOTFS:
            if (relative_cwd[0] != '\0') return false;
            base = "/root";
            break;
        default:
            return false;
    }
    int count = relative_cwd[0] == '\0'
        ? snprintf(output, output_size, "%s", base)
        : snprintf(output, output_size, "%s/%s", base, relative_cwd);
    return count > 0 && (size_t)count < output_size;
}

WujiISHRunResult *wuji_ish_run_stage_d_command(const char *executable,
                                                const uint8_t *argument_blob,
                                                size_t argument_blob_length,
                                                int32_t argument_count,
                                                const char *relative_cwd,
                                                WujiISHStageDRoot root,
                                                size_t output_limit) {
    const char *path = stage_d_executable_path(executable);
    if (path == NULL || argument_count < 0 || argument_count > 16 ||
        argument_blob_length > 8192 || output_limit == 0 || output_limit > 65536 ||
        (argument_count > 0 && argument_blob == NULL))
        return NULL;

    char cwd[2048];
    if (!build_stage_d_cwd(relative_cwd, root, cwd, sizeof(cwd)))
        return NULL;

    char arguments[12288] = {0};
    size_t output_offset = 0;
    if (!append_argument(arguments, sizeof(arguments), &output_offset, path))
        return NULL;
    size_t input_offset = 0;
    for (int32_t index = 0; index < argument_count; index++) {
        if (input_offset >= argument_blob_length)
            return NULL;
        const uint8_t *start = argument_blob + input_offset;
        const uint8_t *terminator = memchr(start, '\0', argument_blob_length - input_offset);
        if (terminator == NULL)
            return NULL;
        size_t length = (size_t)(terminator - start);
        if (!valid_stage_d_argument((const char *)start, length) ||
            !append_argument(arguments, sizeof(arguments), &output_offset, (const char *)start))
            return NULL;
        input_offset += length + 1;
    }
    if (input_offset != argument_blob_length)
        return NULL;
    pthread_mutex_lock(&g_state_lock);
    if (g_stage_d_command_attempt_count != UINT64_MAX)
        g_stage_d_command_attempt_count++;
    pthread_mutex_unlock(&g_state_lock);
    return run_arguments_in_directory(
        path, argument_count + 1, arguments, output_limit, cwd, true
    );
}

static bool valid_sha256(const char *value) {
    if (value == NULL || strlen(value) != 64)
        return false;
    for (size_t index = 0; index < 64; index++) {
        char byte = value[index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')))
            return false;
    }
    return true;
}

static const char s4_edit_script[] =
    "set -eu\n"
    "p=$1\n"
    "old=$2\n"
    "new=$3\n"
    "before=$4\n"
    "after=$5\n"
    "tmp=${p}.wuji-s4-tmp\n"
    "[ -f \"$p\" ] && [ ! -L \"$p\" ] || exit 40\n"
    "actual=$(sha256sum \"$p\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$before\" ] || exit 42\n"
    "[ ! -e \"$tmp\" ] || exit 43\n"
    "trap 'rm -f -- \"$tmp\"' 0 1 2 15\n"
    "awk -v old=\"$old\" -v new=\"$new\" 'BEGIN { count=0 } { if ($0 == old) { count++; print new } else { print } } END { if (count != 1) exit 44 }' \"$p\" > \"$tmp\"\n"
    "actual=$(sha256sum \"$tmp\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$after\" ] || exit 45\n"
    "mv -f -- \"$tmp\" \"$p\"\n"
    "trap - 0 1 2 15\n"
    "actual=$(sha256sum \"$p\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$after\" ] || exit 46\n"
    "printf 'WUJI_S4_EDIT_OK\\n'\n";

WujiISHRunResult *wuji_ish_run_s4_edit(const char *relative_path,
                                       const char *expected_old,
                                       const char *replacement,
                                       const char *before_sha256,
                                       const char *after_sha256,
                                       size_t output_limit) {
    if (!g_s4_workspace_mounted || output_limit == 0 || output_limit > 4096 ||
        relative_path == NULL || strcmp(relative_path, "records/draft.txt") != 0 ||
        expected_old == NULL || strcmp(expected_old, "STATUS=pending") != 0 ||
        replacement == NULL || strcmp(replacement, "STATUS=verified") != 0 ||
        !valid_sha256(before_sha256) || !valid_sha256(after_sha256))
        return NULL;

    char guest_path[1024];
    if (!build_s4_guest_path(relative_path, guest_path, sizeof(guest_path)))
        return NULL;
    char arguments[8192] = {0};
    size_t offset = 0;
    if (!append_argument(arguments, sizeof(arguments), &offset, "/bin/sh") ||
        !append_argument(arguments, sizeof(arguments), &offset, "-c") ||
        !append_argument(arguments, sizeof(arguments), &offset, s4_edit_script) ||
        !append_argument(arguments, sizeof(arguments), &offset, "wuji-s4-edit") ||
        !append_argument(arguments, sizeof(arguments), &offset, guest_path) ||
        !append_argument(arguments, sizeof(arguments), &offset, expected_old) ||
        !append_argument(arguments, sizeof(arguments), &offset, replacement) ||
        !append_argument(arguments, sizeof(arguments), &offset, before_sha256) ||
        !append_argument(arguments, sizeof(arguments), &offset, after_sha256))
        return NULL;
    return run_arguments("/bin/sh", 9, arguments, output_limit);
}

static const char s4_verify_script[] =
    "set -eu\n"
    "draft=$1\n"
    "context=$2\n"
    "after=$3\n"
    "context_hash=$4\n"
    "tmp=${draft}.wuji-s4-tmp\n"
    "[ -f \"$draft\" ] && [ ! -L \"$draft\" ] || exit 50\n"
    "actual=$(sha256sum \"$draft\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$after\" ] || exit 51\n"
    "count=$(grep -Fxc 'STATUS=verified' \"$draft\" || true)\n"
    "[ \"$count\" -eq 1 ] || exit 52\n"
    "if grep -Fxq 'STATUS=pending' \"$draft\"; then exit 53; fi\n"
    "[ -f \"$context\" ] && [ ! -L \"$context\" ] || exit 54\n"
    "actual=$(sha256sum \"$context\"); actual=${actual%% *}\n"
    "[ \"$actual\" = \"$context_hash\" ] || exit 55\n"
    "[ ! -e \"$tmp\" ] || exit 56\n"
    "printf 'WUJI_S4_VERIFY_OK\\n'\n";

WujiISHRunResult *wuji_ish_run_s4_verify(const char *profile,
                                         const char *after_sha256,
                                         const char *context_sha256,
                                         size_t output_limit) {
    if (!g_s4_workspace_mounted || output_limit == 0 || output_limit > 4096 ||
        profile == NULL || strcmp(profile, "s4_status_verified") != 0 ||
        !valid_sha256(after_sha256) || !valid_sha256(context_sha256))
        return NULL;

    char draft_path[1024];
    char context_path[1024];
    if (!build_s4_guest_path("records/draft.txt", draft_path, sizeof(draft_path)) ||
        !build_s4_guest_path("records/context.txt", context_path, sizeof(context_path)))
        return NULL;
    char arguments[8192] = {0};
    size_t offset = 0;
    if (!append_argument(arguments, sizeof(arguments), &offset, "/bin/sh") ||
        !append_argument(arguments, sizeof(arguments), &offset, "-c") ||
        !append_argument(arguments, sizeof(arguments), &offset, s4_verify_script) ||
        !append_argument(arguments, sizeof(arguments), &offset, "wuji-s4-verify") ||
        !append_argument(arguments, sizeof(arguments), &offset, draft_path) ||
        !append_argument(arguments, sizeof(arguments), &offset, context_path) ||
        !append_argument(arguments, sizeof(arguments), &offset, after_sha256) ||
        !append_argument(arguments, sizeof(arguments), &offset, context_sha256))
        return NULL;
    return run_arguments("/bin/sh", 8, arguments, output_limit);
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
size_t wuji_ish_result_stdout_length(const WujiISHRunResult *result) { return result->stdout_stream.length; }
size_t wuji_ish_result_stderr_length(const WujiISHRunResult *result) { return result->stderr_stream.length; }
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
WujiISHProcessTreeKind wuji_ish_result_process_tree_kind(const WujiISHRunResult *result) {
    return result->process_tree_kind;
}
int32_t wuji_ish_result_active_descendant_count(const WujiISHRunResult *result) {
    return result->active_descendant_count;
}
int32_t wuji_ish_result_initial_active_descendant_count(const WujiISHRunResult *result) {
    return result->initial_active_descendant_count;
}
uint32_t wuji_ish_result_process_tree_observation_count(const WujiISHRunResult *result) {
    return result->process_tree_observation_count;
}
bool wuji_ish_result_process_tree_observed_after_terminal_barrier(const WujiISHRunResult *result) {
    return result->process_tree_observed_after_terminal_barrier;
}
WujiISHFixedErrorKind wuji_ish_result_fixed_error_kind(const WujiISHRunResult *result) {
    return result->fixed_error_kind;
}
const char *wuji_ish_result_error(const WujiISHRunResult *result) { return result->error; }

void wuji_ish_result_free(WujiISHRunResult *result) {
    if (result == NULL)
        return;
    free(result->stdout_stream.bytes);
    free(result->stderr_stream.bytes);
    free(result);
}
