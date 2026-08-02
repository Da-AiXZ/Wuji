#ifndef WUJI_STAGE_A_ZIP_BRIDGE_H
#define WUJI_STAGE_A_ZIP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    WUJI_STAGE_A_ZIP_OK = 0,
    WUJI_STAGE_A_ZIP_END = 1,
    WUJI_STAGE_A_ZIP_INVALID_ARGUMENT = -1,
    WUJI_STAGE_A_ZIP_OPEN_FAILED = -2,
    WUJI_STAGE_A_ZIP_FORMAT_FAILED = -3,
    WUJI_STAGE_A_ZIP_BUFFER_TOO_SMALL = -4,
    WUJI_STAGE_A_ZIP_ENTRY_OPEN_FAILED = -5,
    WUJI_STAGE_A_ZIP_ENTRY_READ_FAILED = -6,
    WUJI_STAGE_A_ZIP_OUTPUT_FAILED = -7,
    WUJI_STAGE_A_ZIP_SIZE_MISMATCH = -8
};

typedef struct {
    uint64_t compressed_size;
    uint64_t uncompressed_size;
    uint32_t external_attributes;
    uint32_t path_byte_count;
    uint16_t version_made_by;
    uint16_t general_purpose_flags;
    uint16_t compression_method;
    uint8_t is_directory;
    uint8_t has_directory_marker;
    uint8_t is_symlink;
    uint8_t has_link_name;
    uint8_t is_special_file;
    uint8_t is_supported_host_system;
    uint8_t is_zip64;
    uint8_t reserved;
} wuji_stage_a_zip_entry;

typedef struct wuji_stage_a_zip_reader wuji_stage_a_zip_reader;

int wuji_stage_a_zip_open(const char *archive_path, wuji_stage_a_zip_reader **reader_out);
int wuji_stage_a_zip_first(wuji_stage_a_zip_reader *reader);
int wuji_stage_a_zip_next(wuji_stage_a_zip_reader *reader);
int wuji_stage_a_zip_current_entry(
    wuji_stage_a_zip_reader *reader,
    wuji_stage_a_zip_entry *entry_out,
    char *path_out,
    size_t path_capacity
);
int wuji_stage_a_zip_extract_current_to_fd(
    wuji_stage_a_zip_reader *reader,
    int output_fd,
    uint64_t maximum_bytes,
    uint64_t *written_bytes_out
);
void wuji_stage_a_zip_close(wuji_stage_a_zip_reader **reader);

#ifdef __cplusplus
}
#endif

#endif
