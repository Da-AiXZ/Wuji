#ifndef WUJI_ISH_ADAPTER_H
#define WUJI_ISH_ADAPTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    WUJI_ISH_CASE_SUCCESS = 0,
    WUJI_ISH_CASE_NONZERO = 1,
    WUJI_ISH_CASE_TRUNCATION = 2,
    WUJI_ISH_CASE_CANCELLATION = 3,
    WUJI_ISH_CASE_PROCESS_TREE_TRANSIENT_NONZERO = 4,
    WUJI_ISH_CASE_PROCESS_TREE_PERSISTENT_NONZERO = 5,
    WUJI_ISH_CASE_PROCESS_TREE_CONTEXT_CLEAN = 6,
} WujiISHSelfTestCase;

typedef enum {
    WUJI_ISH_FINAL_UNKNOWN = 0,
    WUJI_ISH_FINAL_EXITED = 1,
    WUJI_ISH_FINAL_SIGNALED = 2,
} WujiISHFinalKind;

typedef enum {
    WUJI_ISH_CANCEL_NOT_REQUESTED = 0,
    WUJI_ISH_CANCEL_SIGNAL_SENT = 1,
    WUJI_ISH_CANCEL_NO_ACTIVE_TASK = 2,
} WujiISHCancelDelivery;

typedef enum {
    WUJI_ISH_READ_ONLY_LIST = 0,
    WUJI_ISH_READ_ONLY_SEARCH = 1,
    WUJI_ISH_READ_ONLY_READ = 2,
} WujiISHReadOnlyOperation;

typedef enum {
    WUJI_ISH_STAGE_D_WORKSPACE = 0,
    WUJI_ISH_STAGE_D_CLONE_ROOT = 1,
    WUJI_ISH_STAGE_D_ROOTFS = 2,
} WujiISHStageDRoot;

typedef enum {
    WUJI_ISH_PROCESS_TREE_NOT_OBSERVED = 0,
    WUJI_ISH_PROCESS_TREE_QUIESCENT = 1,
    WUJI_ISH_PROCESS_TREE_DESCENDANTS_REMAIN = 2,
} WujiISHProcessTreeKind;

typedef enum {
    WUJI_ISH_FIXED_ERROR_NONE = 0,
    WUJI_ISH_FIXED_ERROR_INVALID_INPUT = 1,
    WUJI_ISH_FIXED_ERROR_NOT_PREPARED = 2,
    WUJI_ISH_FIXED_ERROR_HOST_PIPE = 3,
    WUJI_ISH_FIXED_ERROR_GUEST_TASK = 4,
    WUJI_ISH_FIXED_ERROR_GUEST_CWD = 5,
    WUJI_ISH_FIXED_ERROR_GUEST_STDIO = 6,
    WUJI_ISH_FIXED_ERROR_GUEST_EXEC = 7,
    WUJI_ISH_FIXED_ERROR_STDOUT_READER = 8,
    WUJI_ISH_FIXED_ERROR_STDERR_READER = 9,
    WUJI_ISH_FIXED_ERROR_INTERNAL = 10,
} WujiISHFixedErrorKind;

typedef enum {
    WUJI_ISH_STAGE_D_NODE_MISSING = 0,
    WUJI_ISH_STAGE_D_NODE_DIRECTORY = 1,
    WUJI_ISH_STAGE_D_NODE_REGULAR_FILE = 2,
    WUJI_ISH_STAGE_D_NODE_SYMBOLIC_LINK = 3,
    WUJI_ISH_STAGE_D_NODE_OTHER = 4,
    WUJI_ISH_STAGE_D_NODE_UNKNOWN = 5,
} WujiISHStageDNodeType;

typedef enum {
    WUJI_ISH_STAGE_D_FILESYSTEM_NONE = 0,
    WUJI_ISH_STAGE_D_FILESYSTEM_PERMISSION_READONLY = 1,
    WUJI_ISH_STAGE_D_FILESYSTEM_NAME_PATH_LIMIT = 2,
    WUJI_ISH_STAGE_D_FILESYSTEM_FILEMODE_CHMOD = 3,
    WUJI_ISH_STAGE_D_FILESYSTEM_CREATE_MKDIR_OPEN = 4,
    WUJI_ISH_STAGE_D_FILESYSTEM_DESTINATION_STATE = 5,
    WUJI_ISH_STAGE_D_FILESYSTEM_CAPACITY_INODE = 6,
    WUJI_ISH_STAGE_D_FILESYSTEM_BIND_IDENTITY = 7,
    WUJI_ISH_STAGE_D_FILESYSTEM_GENERIC = 8,
} WujiISHStageDFilesystemCategory;

typedef enum {
    WUJI_ISH_STAGE_D_PROBE_NOT_RUN = 0,
    WUJI_ISH_STAGE_D_PROBE_SUCCEEDED = 1,
    WUJI_ISH_STAGE_D_PROBE_FAILED = 2,
    WUJI_ISH_STAGE_D_PROBE_UNKNOWN = 3,
} WujiISHStageDProbeStepState;

typedef struct {
    bool complete;
    bool binding_matches;
    bool parent_exists;
    WujiISHStageDNodeType parent_type;
    bool parent_is_empty;
    bool parent_is_symlink;
    bool target_exists;
    WujiISHStageDNodeType target_type;
    bool target_is_empty;
    bool target_is_symlink;
    bool probe_names_absent;
    bool mount_read_only;
    uint32_t umask_value;
    uint64_t name_max;
    uint64_t path_max;
    uint64_t available_bytes;
    uint64_t available_inodes;
} WujiISHStageDClonePreflight;

typedef struct {
    WujiISHStageDProbeStepState create_state;
    WujiISHStageDProbeStepState fchmod_state;
    WujiISHStageDProbeStepState fsync_state;
    WujiISHStageDProbeStepState rename_state;
    WujiISHStageDProbeStepState unlink_state;
    WujiISHStageDFilesystemCategory failure_category;
    bool cleanup_known;
    bool cleanup_verified;
} WujiISHStageDCloneCapabilityProbe;

typedef struct WujiISHRunResult WujiISHRunResult;

int wuji_ish_prepare(const char *archive_path,
                     const char *root_path,
                     char *error_buffer,
                     size_t error_buffer_size);

int wuji_ish_configure_stage_d_system_resolver(uint32_t *nameserver_count,
                                                uint32_t *search_domain_count,
                                                size_t *configuration_bytes,
                                                uint32_t *configuration_count,
                                                char *error_buffer,
                                                size_t error_buffer_size);

uint64_t wuji_ish_stage_d_command_attempt_count(void);

int wuji_ish_mount_read_only_workspace(const char *host_path,
                                       char *error_buffer,
                                       size_t error_buffer_size);

int wuji_ish_mount_s4_workspace(const char *host_path,
                                char *error_buffer,
                                size_t error_buffer_size);

int wuji_ish_mount_stage_b_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size);

int wuji_ish_mount_stage_c_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size);

int wuji_ish_mount_stage_d_workspace(const char *host_path,
                                     char *error_buffer,
                                     size_t error_buffer_size);

int wuji_ish_mount_stage_d_clone_root(const char *host_path,
                                       char *error_buffer,
                                       size_t error_buffer_size);

int wuji_ish_stage_d_clone_preflight(const char *expected_host_root,
                                     WujiISHStageDClonePreflight *preflight);

int wuji_ish_stage_d_clone_capability_probe(WujiISHStageDCloneCapabilityProbe *probe);

WujiISHRunResult *wuji_ish_run_self_test(WujiISHSelfTestCase test_case,
                                         size_t output_limit);

WujiISHRunResult *wuji_ish_run_read_only(WujiISHReadOnlyOperation operation,
                                         const char *relative_path,
                                         const char *query,
                                         size_t output_limit);

WujiISHRunResult *wuji_ish_run_s4_read_only(WujiISHReadOnlyOperation operation,
                                             const char *relative_path,
                                             const char *query,
                                             size_t output_limit);

WujiISHRunResult *wuji_ish_run_stage_b_read_only(WujiISHReadOnlyOperation operation,
                                                   const char *relative_path,
                                                   const char *query,
                                                   size_t output_limit);

WujiISHRunResult *wuji_ish_run_stage_c_edit(const char *relative_path,
                                            const char *expected_old,
                                            const char *replacement,
                                            const char *before_sha256,
                                            const char *after_sha256,
                                            size_t output_limit);

WujiISHRunResult *wuji_ish_run_stage_d_command(const char *executable,
                                                const uint8_t *argument_blob,
                                                size_t argument_blob_length,
                                                int32_t argument_count,
                                                const char *relative_cwd,
                                                WujiISHStageDRoot root,
                                                size_t output_limit);

WujiISHRunResult *wuji_ish_run_s4_edit(const char *relative_path,
                                       const char *expected_old,
                                       const char *replacement,
                                       const char *before_sha256,
                                       const char *after_sha256,
                                       size_t output_limit);

WujiISHRunResult *wuji_ish_run_s4_verify(const char *profile,
                                         const char *after_sha256,
                                         const char *context_sha256,
                                         size_t output_limit);

WujiISHCancelDelivery wuji_ish_request_cancel(void);

const char *wuji_ish_result_stdout(const WujiISHRunResult *result);
const char *wuji_ish_result_stderr(const WujiISHRunResult *result);
size_t wuji_ish_result_stdout_length(const WujiISHRunResult *result);
size_t wuji_ish_result_stderr_length(const WujiISHRunResult *result);
bool wuji_ish_result_stdout_eof(const WujiISHRunResult *result);
bool wuji_ish_result_stderr_eof(const WujiISHRunResult *result);
bool wuji_ish_result_root_exited(const WujiISHRunResult *result);
bool wuji_ish_result_truncated(const WujiISHRunResult *result);
bool wuji_ish_result_cancellation_requested(const WujiISHRunResult *result);
WujiISHCancelDelivery wuji_ish_result_cancel_delivery(const WujiISHRunResult *result);
WujiISHFinalKind wuji_ish_result_final_kind(const WujiISHRunResult *result);
int32_t wuji_ish_result_final_value(const WujiISHRunResult *result);
WujiISHProcessTreeKind wuji_ish_result_process_tree_kind(const WujiISHRunResult *result);
int32_t wuji_ish_result_active_descendant_count(const WujiISHRunResult *result);
int32_t wuji_ish_result_initial_active_descendant_count(const WujiISHRunResult *result);
uint32_t wuji_ish_result_process_tree_observation_count(const WujiISHRunResult *result);
bool wuji_ish_result_process_tree_observed_after_terminal_barrier(const WujiISHRunResult *result);
bool wuji_ish_process_tree_task_state_is_active(uint64_t process_context,
                                                uint64_t task_process_context,
                                                bool zombie,
                                                bool exiting);
WujiISHFixedErrorKind wuji_ish_result_fixed_error_kind(const WujiISHRunResult *result);
const char *wuji_ish_result_error(const WujiISHRunResult *result);
void wuji_ish_result_free(WujiISHRunResult *result);

#endif
