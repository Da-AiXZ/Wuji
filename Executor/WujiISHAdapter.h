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
bool wuji_ish_result_process_tree_observed_after_terminal_barrier(const WujiISHRunResult *result);
WujiISHFixedErrorKind wuji_ish_result_fixed_error_kind(const WujiISHRunResult *result);
const char *wuji_ish_result_error(const WujiISHRunResult *result);
void wuji_ish_result_free(WujiISHRunResult *result);

#endif
