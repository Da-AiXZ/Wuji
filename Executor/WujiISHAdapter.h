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

typedef struct WujiISHRunResult WujiISHRunResult;

int wuji_ish_prepare(const char *archive_path,
                     const char *root_path,
                     char *error_buffer,
                     size_t error_buffer_size);

int wuji_ish_mount_read_only_workspace(const char *host_path,
                                       char *error_buffer,
                                       size_t error_buffer_size);

int wuji_ish_mount_s4_workspace(const char *host_path,
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
bool wuji_ish_result_stdout_eof(const WujiISHRunResult *result);
bool wuji_ish_result_stderr_eof(const WujiISHRunResult *result);
bool wuji_ish_result_root_exited(const WujiISHRunResult *result);
bool wuji_ish_result_truncated(const WujiISHRunResult *result);
bool wuji_ish_result_cancellation_requested(const WujiISHRunResult *result);
WujiISHCancelDelivery wuji_ish_result_cancel_delivery(const WujiISHRunResult *result);
WujiISHFinalKind wuji_ish_result_final_kind(const WujiISHRunResult *result);
int32_t wuji_ish_result_final_value(const WujiISHRunResult *result);
const char *wuji_ish_result_error(const WujiISHRunResult *result);
void wuji_ish_result_free(WujiISHRunResult *result);

#endif
