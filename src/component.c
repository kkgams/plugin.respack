#include "respack_plugin.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern uint32_t respack_core_build(const uint8_t *schema_ptr, uintptr_t schema_len, const uint8_t *slots_ptr, uintptr_t slots_len);
extern uint32_t respack_core_generate_odin(const uint8_t *schema_ptr, uintptr_t schema_len);
extern const uint8_t *respack_core_output_ptr(void);
extern uintptr_t respack_core_output_len(void);

static void set_error(respack_plugin_string_t *err, const char *message) {
  respack_plugin_string_dup(err, message);
}

static void set_wasi_error(respack_plugin_string_t *err, const char *prefix,
                           wasi_filesystem_types_error_code_t code) {
  char buffer[96];
  const char *name = "unknown";
  switch (code) {
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_ACCESS: name = "access"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_NO_ENTRY: name = "no-entry"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_NOT_DIRECTORY: name = "not-directory"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_IS_DIRECTORY: name = "is-directory"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_NOT_PERMITTED: name = "not-permitted"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_READ_ONLY: name = "read-only"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_EXIST: name = "exist"; break;
  case WASI_FILESYSTEM_TYPES_ERROR_CODE_IO: name = "io"; break;
  default: break;
  }
  size_t prefix_len = strlen(prefix);
  size_t name_len = strlen(name);
  size_t pos = 0;
  if (prefix_len > sizeof(buffer) - 1) prefix_len = sizeof(buffer) - 1;
  memcpy(buffer + pos, prefix, prefix_len);
  pos += prefix_len;
  if (pos + 2 < sizeof(buffer)) {
    buffer[pos++] = ':';
    buffer[pos++] = ' ';
  }
  if (name_len > sizeof(buffer) - 1 - pos) name_len = sizeof(buffer) - 1 - pos;
  memcpy(buffer + pos, name, name_len);
  pos += name_len;
  buffer[pos] = '\0';
  set_error(err, buffer);
}

static bool string_eq_bytes(const uint8_t *ptr, size_t len, const char *literal) {
  size_t literal_len = strlen(literal);
  return len == literal_len && memcmp(ptr, literal, len) == 0;
}

static bool preopen_matches_path(const respack_plugin_string_t *preopen_path,
                                 const respack_plugin_string_t *path,
                                 size_t *relative_offset) {
  if (string_eq_bytes(preopen_path->ptr, preopen_path->len, "/")) {
    if (path->len == 0 || path->ptr[0] != '/') return false;
    *relative_offset = 1;
    return true;
  }
  if (path->len < preopen_path->len ||
      memcmp(path->ptr, preopen_path->ptr, preopen_path->len) != 0) {
    return false;
  }
  if (path->len == preopen_path->len) {
    *relative_offset = path->len;
    return true;
  }
  if (path->ptr[preopen_path->len] != '/') return false;
  *relative_offset = preopen_path->len + 1;
  return true;
}

static bool resolve_wasi_path(
    respack_plugin_string_t *path,
    wasi_filesystem_preopens_list_tuple2_own_descriptor_string_t *preopens,
    wasi_filesystem_types_borrow_descriptor_t *ret_base,
    respack_plugin_string_t *ret_relative,
    respack_plugin_string_t *err) {
  wasi_filesystem_preopens_get_directories(preopens);
  if (preopens->len == 0) {
    set_error(err, "no wasi filesystem preopens");
    return false;
  }
  if (path->len == 0) {
    wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(preopens);
    set_error(err, "invalid respack output path");
    return false;
  }

  bool is_absolute = path->ptr[0] == '/';
  bool found = false;
  size_t index = 0;
  size_t offset = 0;
  size_t best_len = 0;

  for (size_t i = 0; i < preopens->len; i++) {
    respack_plugin_string_t *guest = &preopens->ptr[i].f1;
    bool guest_is_absolute = guest->len > 0 && guest->ptr[0] == '/';
    if (string_eq_bytes(guest->ptr, guest->len, ".") ||
        guest_is_absolute != is_absolute) {
      continue;
    }
    size_t candidate_offset = 0;
    if (!preopen_matches_path(guest, path, &candidate_offset)) continue;
    if (!found || guest->len > best_len) {
      found = true;
      index = i;
      offset = candidate_offset;
      best_len = guest->len;
    }
  }

  if (!found && !is_absolute) {
    for (size_t i = 0; i < preopens->len; i++) {
      respack_plugin_string_t *guest = &preopens->ptr[i].f1;
      if (string_eq_bytes(guest->ptr, guest->len, ".")) {
        found = true;
        index = i;
        offset = 0;
        break;
      }
    }
  }

  if (!found || path->len <= offset) {
    wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(preopens);
    set_error(err, found ? "invalid respack output path" : "respack output path is not under a WASI preopen");
    return false;
  }

  *ret_base = wasi_filesystem_types_borrow_descriptor(preopens->ptr[index].f0);
  ret_relative->ptr = path->ptr + offset;
  ret_relative->len = path->len - offset;
  return true;
}

static bool write_all_bytes(respack_plugin_string_t *path, const uint8_t *data,
                            size_t len, respack_plugin_string_t *err) {
  wasi_filesystem_preopens_list_tuple2_own_descriptor_string_t preopens;
  wasi_filesystem_types_borrow_descriptor_t base;
  respack_plugin_string_t relative;
  if (!resolve_wasi_path(path, &preopens, &base, &relative, err)) return false;

  wasi_filesystem_types_own_descriptor_t file;
  wasi_filesystem_types_error_code_t code = 0;
  if (!wasi_filesystem_types_method_descriptor_open_at(
          base, 0, &relative,
          WASI_FILESYSTEM_TYPES_OPEN_FLAGS_CREATE | WASI_FILESYSTEM_TYPES_OPEN_FLAGS_TRUNCATE,
          WASI_FILESYSTEM_TYPES_DESCRIPTOR_FLAGS_WRITE, &file, &code)) {
    wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(&preopens);
    set_wasi_error(err, "failed to open respack output file", code);
    return false;
  }

  wasi_filesystem_types_borrow_descriptor_t borrowed = wasi_filesystem_types_borrow_descriptor(file);
  size_t offset = 0;
  while (offset < len) {
    respack_plugin_list_u8_t chunk = {
      .ptr = (uint8_t *)data + offset,
      .len = len - offset,
    };
    wasi_filesystem_types_filesize_t written = 0;
    code = 0;
    if (!wasi_filesystem_types_method_descriptor_write(borrowed, &chunk, offset, &written, &code)) {
      wasi_filesystem_types_descriptor_drop_own(file);
      wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(&preopens);
      set_wasi_error(err, "failed to write respack output file", code);
      return false;
    }
    if (written == 0) {
      wasi_filesystem_types_descriptor_drop_own(file);
      wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(&preopens);
      set_error(err, "respack output write returned zero bytes");
      return false;
    }
    offset += (size_t)written;
  }

  code = 0;
  if (!wasi_filesystem_types_method_descriptor_sync(borrowed, &code)) {
    wasi_filesystem_types_descriptor_drop_own(file);
    wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(&preopens);
    set_wasi_error(err, "failed to sync respack output file", code);
    return false;
  }

  wasi_filesystem_types_descriptor_drop_own(file);
  wasi_filesystem_preopens_list_tuple2_own_descriptor_string_free(&preopens);
  return true;
}

static void set_string_from_core(respack_plugin_string_t *ret) {
  uintptr_t len = respack_core_output_len();
  const uint8_t *ptr = respack_core_output_ptr();
  respack_plugin_string_dup_n(ret, (const char *)ptr, (size_t)len);
}

static void set_list_from_core(respack_plugin_list_u8_t *ret) {
  uintptr_t len = respack_core_output_len();
  const uint8_t *ptr = respack_core_output_ptr();
  ret->len = (size_t)len;
  if (len == 0) {
    ret->ptr = NULL;
    return;
  }
  ret->ptr = (uint8_t *)malloc((size_t)len);
  memcpy(ret->ptr, ptr, (size_t)len);
}

bool exports_gams_respack_respack_generate_odin(respack_plugin_string_t *schema, respack_plugin_string_t *ret, respack_plugin_string_t *err) {
  uint32_t status = respack_core_generate_odin(schema->ptr, (uintptr_t)schema->len);
  if (status != 0) {
    set_string_from_core(err);
    return false;
  }
  set_string_from_core(ret);
  return true;
}

bool exports_gams_respack_respack_build(respack_plugin_string_t *schema, respack_plugin_string_t *slots_json, respack_plugin_list_u8_t *ret, respack_plugin_string_t *err) {
  uint32_t status = respack_core_build(schema->ptr, (uintptr_t)schema->len, slots_json->ptr, (uintptr_t)slots_json->len);
  if (status != 0) {
    set_string_from_core(err);
    return false;
  }
  set_list_from_core(ret);
  return true;
}

bool exports_gams_respack_respack_build_to_file(respack_plugin_string_t *schema, respack_plugin_string_t *slots_json, respack_plugin_string_t *path, uint64_t *ret, respack_plugin_string_t *err) {
  uint32_t status = respack_core_build(schema->ptr, (uintptr_t)schema->len, slots_json->ptr, (uintptr_t)slots_json->len);
  if (status != 0) {
    set_string_from_core(err);
    return false;
  }
  uintptr_t len = respack_core_output_len();
  if (!write_all_bytes(path, respack_core_output_ptr(), (size_t)len, err)) {
    return false;
  }
  *ret = (uint64_t)len;
  return true;
}
