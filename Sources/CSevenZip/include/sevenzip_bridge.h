#ifndef SEVENZIP_BRIDGE_H
#define SEVENZIP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum sz_status {
    SZ_STATUS_OK = 0,
    SZ_STATUS_ERR_OPEN = 1,
    SZ_STATUS_ERR_PASSWORD_REQUIRED = 2,
    SZ_STATUS_ERR_WRONG_PASSWORD = 3,
    SZ_STATUS_ERR_CORRUPT = 4,
    SZ_STATUS_ERR_UNSUPPORTED = 5,
    SZ_STATUS_ERR_CANCELLED = 6,
    SZ_STATUS_ERR_IO = 7,
    SZ_STATUS_ERR_INVALID_ARG = 8,
    SZ_STATUS_ERR_INTERNAL = 9
} sz_status_t;

typedef enum sz_overwrite_mode {
    SZ_OVERWRITE_ASK = 0,
    SZ_OVERWRITE_ALL = 1,
    SZ_OVERWRITE_SKIP = 2,
    SZ_OVERWRITE_AUTO_RENAME = 3,
    SZ_OVERWRITE_AUTO_RENAME_EXISTING = 4
} sz_overwrite_mode_t;

typedef struct sz_archive sz_archive_t;

typedef struct sz_format_info {
    char *name;
    char *extensions;
    bool updatable;
    bool keep_name;
} sz_format_info_t;

typedef struct sz_archive_summary {
    char *format_name;
    char *outer_format_name;
    char *comment;
    uint64_t physical_size;
    uint64_t headers_size;
    uint32_t item_count;
    uint32_t num_volumes;
    bool is_solid;
    bool is_multi_volume;
    bool is_updatable;
    bool headers_encrypted;
} sz_archive_summary_t;

typedef struct sz_item_info {
    uint32_t index;
    char *path;
    uint64_t size;
    uint64_t packed_size;
    bool has_size;
    bool has_packed_size;
    int64_t mtime_sec;
    int32_t mtime_nsec;
    bool has_mtime;
    uint32_t posix_mode;
    char *attributes;
    uint32_t crc32;
    bool has_crc32;
    char *method;
    char *symlink_target;
    bool is_dir;
    bool is_encrypted;
    bool is_symlink;
} sz_item_info_t;

typedef struct sz_update_options {
    const char *format_name;       // e.g. "7z", "zip", "tar", "wim", "xz", "gzip", "bzip2" (NULL = infer from path)
    const char *method;            // e.g. "LZMA2", "LZMA", "PPMd", "BZip2", "Deflate", "Copy" (NULL = format default)
    int32_t compression_level;     // 0..9 (-1 = default)
    uint32_t dictionary_size_kb;   // 0 = default
    int32_t num_threads;           // 0 = auto
    int64_t solid_block_bytes;     // -1 = default, 0 = non-solid (-ms=off), >0 = solid size in bytes
    uint64_t volume_bytes;         // 0 = single file, >0 = split into volumes of N bytes
    bool encrypt_headers;          // -mhe=on (7z only)
    bool store_symlinks;           // preserve symbolic links as links (-snl)
} sz_update_options_t;

// Returns true to continue operation, false to cancel (triggers SZ_STATUS_ERR_CANCELLED).
typedef bool (*sz_progress_cb)(uint64_t completed, uint64_t total, const char *current_item, void *user_data);

// Optional callback invoked when an archive requires a password and none was pre-supplied.
// Must return a heap-allocated UTF-8 C string (allocated via malloc/strdup), or NULL to cancel.
// The bridge zeroes and frees the returned buffer after copying.
typedef char *(*sz_password_cb)(void *user_data);

const char *sz_version_string(void);

sz_status_t sz_get_supported_formats(
    sz_format_info_t **out_formats,
    uint32_t *out_count,
    char **out_error
);
void sz_free_formats(sz_format_info_t *formats, uint32_t count);

sz_status_t sz_archive_open(
    const char *path,
    const char *password,
    sz_password_cb password_cb,
    void *user_data,
    sz_archive_t **out_archive,
    char **out_error
);
void sz_archive_close(sz_archive_t *archive);

sz_status_t sz_archive_get_summary(
    const sz_archive_t *archive,
    sz_archive_summary_t *out_summary,
    char **out_error
);
void sz_free_summary(sz_archive_summary_t *summary);

sz_status_t sz_archive_get_items(
    const sz_archive_t *archive,
    sz_item_info_t **out_items,
    uint32_t *out_count,
    char **out_error
);
void sz_free_items(sz_item_info_t *items, uint32_t count);

sz_status_t sz_archive_extract(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *dest_dir,
    const char *strip_prefix,
    bool full_paths,
    sz_overwrite_mode_t overwrite_mode,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
);

sz_status_t sz_archive_test(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
);

sz_status_t sz_archive_extract_to_memory(
    sz_archive_t *archive,
    uint32_t index,
    uint64_t max_bytes,
    const char *password,
    sz_password_cb password_cb,
    uint8_t **out_data,
    size_t *out_size,
    char **out_error
);

sz_status_t sz_archive_update(
    const char *archive_path,
    const char * const *input_paths,
    uint32_t input_count,
    const char *base_dir,
    const sz_update_options_t *options,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
);

sz_status_t sz_archive_delete_items(
    const char *archive_path,
    const char * const *archive_item_paths,
    uint32_t path_count,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
);

sz_status_t sz_archive_rename_items(
    const char *archive_path,
    const char * const *old_paths,
    const char * const *new_paths,
    uint32_t pair_count,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
);

void sz_string_free(char *str);
void sz_buffer_free(uint8_t *buf);

#ifdef __cplusplus
}
#endif

#endif // SEVENZIP_BRIDGE_H
