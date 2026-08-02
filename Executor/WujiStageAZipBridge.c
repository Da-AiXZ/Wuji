#include "WujiStageAZipBridge.h"

#include "mz.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct wuji_stage_a_zip_reader {
    void *handle;
};

static int map_navigation_result(int32_t result) {
    if (result == MZ_OK)
        return WUJI_STAGE_A_ZIP_OK;
    if (result == MZ_END_OF_LIST)
        return WUJI_STAGE_A_ZIP_END;
    return WUJI_STAGE_A_ZIP_FORMAT_FAILED;
}

int wuji_stage_a_zip_open(const char *archive_path, wuji_stage_a_zip_reader **reader_out) {
    if (!archive_path || !reader_out || *reader_out)
        return WUJI_STAGE_A_ZIP_INVALID_ARGUMENT;
    wuji_stage_a_zip_reader *reader = calloc(1, sizeof(*reader));
    if (!reader)
        return WUJI_STAGE_A_ZIP_OPEN_FAILED;
    reader->handle = mz_zip_reader_create();
    if (!reader->handle) {
        free(reader);
        return WUJI_STAGE_A_ZIP_OPEN_FAILED;
    }
    if (mz_zip_reader_open_file(reader->handle, archive_path) != MZ_OK) {
        mz_zip_reader_delete(&reader->handle);
        free(reader);
        return WUJI_STAGE_A_ZIP_OPEN_FAILED;
    }
    *reader_out = reader;
    return WUJI_STAGE_A_ZIP_OK;
}

int wuji_stage_a_zip_first(wuji_stage_a_zip_reader *reader) {
    if (!reader || !reader->handle)
        return WUJI_STAGE_A_ZIP_INVALID_ARGUMENT;
    return map_navigation_result(mz_zip_reader_goto_first_entry(reader->handle));
}

int wuji_stage_a_zip_next(wuji_stage_a_zip_reader *reader) {
    if (!reader || !reader->handle)
        return WUJI_STAGE_A_ZIP_INVALID_ARGUMENT;
    return map_navigation_result(mz_zip_reader_goto_next_entry(reader->handle));
}

int wuji_stage_a_zip_current_entry(
    wuji_stage_a_zip_reader *reader,
    wuji_stage_a_zip_entry *entry_out,
    char *path_out,
    size_t path_capacity
) {
    if (!reader || !reader->handle || !entry_out || !path_out || path_capacity == 0)
        return WUJI_STAGE_A_ZIP_INVALID_ARGUMENT;
    mz_zip_file *file = NULL;
    if (mz_zip_reader_entry_get_info(reader->handle, &file) != MZ_OK || !file || !file->filename)
        return WUJI_STAGE_A_ZIP_FORMAT_FAILED;
    if (file->compressed_size < 0 || file->uncompressed_size < 0)
        return WUJI_STAGE_A_ZIP_FORMAT_FAILED;

    size_t path_bytes = strlen(file->filename);
    if (path_bytes != file->filename_size)
        return WUJI_STAGE_A_ZIP_FORMAT_FAILED;
    if (path_bytes + 1 > path_capacity || path_bytes > UINT32_MAX)
        return WUJI_STAGE_A_ZIP_BUFFER_TOO_SMALL;
    uint8_t host_system = MZ_HOST_SYSTEM(file->version_madeby);
    uint8_t supported_host = host_system == MZ_HOST_SYSTEM_MSDOS ||
        host_system == MZ_HOST_SYSTEM_WINDOWS_NTFS ||
        host_system == MZ_HOST_SYSTEM_UNIX ||
        host_system == MZ_HOST_SYSTEM_OSX_DARWIN ||
        host_system == MZ_HOST_SYSTEM_RISCOS;
    uint32_t posix_attributes = 0;
    int32_t converted = mz_zip_attrib_convert(
        host_system, file->external_fa, MZ_HOST_SYSTEM_UNIX, &posix_attributes
    );
    uint32_t file_type = posix_attributes & S_IFMT;
    uint8_t directory = mz_zip_attrib_is_dir(file->external_fa, file->version_madeby) == MZ_OK;
    uint8_t symlink = mz_zip_attrib_is_symlink(file->external_fa, file->version_madeby) == MZ_OK;
    uint8_t marker = path_bytes > 0 && file->filename[path_bytes - 1] == '/';
    uint8_t special = !supported_host || converted != MZ_OK ||
        (file_type != S_IFREG && file_type != S_IFDIR && file_type != S_IFLNK);

    memcpy(path_out, file->filename, path_bytes + 1);
    memset(entry_out, 0, sizeof(*entry_out));
    entry_out->compressed_size = (uint64_t)file->compressed_size;
    entry_out->uncompressed_size = (uint64_t)file->uncompressed_size;
    entry_out->external_attributes = file->external_fa;
    entry_out->path_byte_count = (uint32_t)path_bytes;
    entry_out->version_made_by = file->version_madeby;
    entry_out->general_purpose_flags = file->flag;
    entry_out->compression_method = file->compression_method;
    entry_out->is_directory = directory;
    entry_out->has_directory_marker = marker;
    entry_out->is_symlink = symlink;
    entry_out->has_link_name = file->linkname && file->linkname[0] != '\0';
    entry_out->is_special_file = special;
    entry_out->is_supported_host_system = supported_host;
    entry_out->is_zip64 = file->zip64 != 0;
    return WUJI_STAGE_A_ZIP_OK;
}

int wuji_stage_a_zip_extract_current_to_fd(
    wuji_stage_a_zip_reader *reader,
    int output_fd,
    uint64_t maximum_bytes,
    uint64_t *written_bytes_out
) {
    if (!reader || !reader->handle || output_fd < 0 || !written_bytes_out)
        return WUJI_STAGE_A_ZIP_INVALID_ARGUMENT;
    mz_zip_file *file = NULL;
    if (mz_zip_reader_entry_get_info(reader->handle, &file) != MZ_OK || !file || file->uncompressed_size < 0)
        return WUJI_STAGE_A_ZIP_FORMAT_FAILED;
    if ((uint64_t)file->uncompressed_size > maximum_bytes)
        return WUJI_STAGE_A_ZIP_SIZE_MISMATCH;
    if (mz_zip_reader_entry_open(reader->handle) != MZ_OK)
        return WUJI_STAGE_A_ZIP_ENTRY_OPEN_FAILED;

    uint8_t buffer[64 * 1024];
    uint64_t written_total = 0;
    int result = WUJI_STAGE_A_ZIP_OK;
    for (;;) {
        int32_t count = mz_zip_reader_entry_read(reader->handle, buffer, sizeof(buffer));
        if (count < 0) {
            result = WUJI_STAGE_A_ZIP_ENTRY_READ_FAILED;
            break;
        }
        if (count == 0)
            break;
        if ((uint64_t)count > maximum_bytes ||
            written_total > maximum_bytes - (uint64_t)count) {
            result = WUJI_STAGE_A_ZIP_SIZE_MISMATCH;
            break;
        }
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t emitted = write(output_fd, buffer + offset, (size_t)count - offset);
            if (emitted < 0 && errno == EINTR)
                continue;
            if (emitted <= 0) {
                result = WUJI_STAGE_A_ZIP_OUTPUT_FAILED;
                break;
            }
            offset += (size_t)emitted;
        }
        if (result != WUJI_STAGE_A_ZIP_OK)
            break;
        written_total += (uint64_t)count;
    }
    int32_t close_result = mz_zip_reader_entry_close(reader->handle);
    if (result == WUJI_STAGE_A_ZIP_OK && close_result != MZ_OK)
        result = WUJI_STAGE_A_ZIP_ENTRY_READ_FAILED;
    if (result == WUJI_STAGE_A_ZIP_OK && written_total != (uint64_t)file->uncompressed_size)
        result = WUJI_STAGE_A_ZIP_SIZE_MISMATCH;
    *written_bytes_out = written_total;
    return result;
}

void wuji_stage_a_zip_close(wuji_stage_a_zip_reader **reader) {
    if (!reader || !*reader)
        return;
    if ((*reader)->handle) {
        mz_zip_reader_close((*reader)->handle);
        mz_zip_reader_delete(&(*reader)->handle);
    }
    free(*reader);
    *reader = NULL;
}
