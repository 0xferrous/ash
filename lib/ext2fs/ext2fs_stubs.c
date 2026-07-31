#define _FILE_OFFSET_BITS 64
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <errno.h>
#include <ext2fs/ext2fs.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct ash_ext2fs_handle {
  ext2_filsys fs;
  char *path;
};

#define Handle_val(v) (*((struct ash_ext2fs_handle **)Data_custom_val(v)))

static void raise_error(const char *operation, errcode_t error) {
  char message[1024];
  snprintf(message, sizeof(message), "%s: %s", operation,
           error_message(error));
  caml_failwith(message);
}

static void raise_errno(const char *operation, const char *path) {
  char message[1024];
  snprintf(message, sizeof(message), "%s %s: %s", operation, path,
           strerror(errno));
  caml_failwith(message);
}

static void fix_itable_unused(ext2_filsys fs) {
  ext2_ino_t inodes_per_group = fs->super->s_inodes_per_group;
  for (dgrp_t group = 0; group < fs->group_desc_count; group++) {
    ext2_ino_t first = group * inodes_per_group + 1;
    ext2_ino_t end = first + inodes_per_group - 1;
    if (end > fs->super->s_inodes_count)
      end = fs->super->s_inodes_count;
    ext2_ino_t highest = 0;
    for (ext2_ino_t ino = end; ino >= first; ino--) {
      if (ext2fs_test_inode_bitmap2(fs->inode_map, ino)) {
        highest = ino;
        break;
      }
      if (ino == first)
        break;
    }
    if (highest == 0) {
      ext2fs_bg_flags_set(fs, group, EXT2_BG_INODE_UNINIT);
      ext2fs_bg_itable_unused_set(fs, group, inodes_per_group);
    } else {
      ext2fs_bg_flags_clear(fs, group, EXT2_BG_INODE_UNINIT);
      ext2fs_bg_itable_unused_set(
          fs, group, group * inodes_per_group + inodes_per_group - highest);
    }
    ext2fs_group_desc_csum_set(fs, group);
  }
  ext2fs_mark_super_dirty(fs);
}

static void close_handle(struct ash_ext2fs_handle *handle, int raise) {
  if (handle == NULL || handle->fs == NULL)
    return;
  ext2fs_calculate_summary_stats(handle->fs, 0);
  fix_itable_unused(handle->fs);
  errcode_t error = ext2fs_close(handle->fs);
  handle->fs = NULL;
  if (error && raise)
    raise_error("closing ext4 image", error);
}

static void finalize_handle(value value_handle) {
  struct ash_ext2fs_handle *handle = Handle_val(value_handle);
  if (handle != NULL) {
    close_handle(handle, 0);
    free(handle->path);
    free(handle);
    Handle_val(value_handle) = NULL;
  }
}

static struct custom_operations handle_ops = {
    "ash.ext2fs.handle", finalize_handle, custom_compare_default,
    custom_hash_default, custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

static struct ash_ext2fs_handle *get_handle(value value_handle) {
  struct ash_ext2fs_handle *handle = Handle_val(value_handle);
  if (handle == NULL || handle->fs == NULL)
    caml_failwith("ext4 image is closed");
  return handle;
}

static int block_log(int block_size) {
  switch (block_size) {
  case 1024:
    return 0;
  case 2048:
    return 1;
  case 4096:
    return 2;
  default:
    caml_invalid_argument("Ext2fs.create: block size must be 1024, 2048, or 4096");
  }
}

static void validate_path(const char *path) {
  if (path == NULL || path[0] != '/')
    caml_invalid_argument("Ext2fs: paths must be absolute");
  const char *p = path;
  while (*p) {
    while (*p == '/')
      p++;
    const char *start = p;
    while (*p && *p != '/')
      p++;
    if (p - start == 2 && start[0] == '.' && start[1] == '.')
      caml_invalid_argument("Ext2fs: '..' path components are forbidden");
  }
}

static void set_inode_metadata(ext2_filsys fs, ext2_ino_t ino, int type,
                               int mode, int uid, int gid, double mtime) {
  struct ext2_inode inode;
  errcode_t error = ext2fs_read_inode(fs, ino, &inode);
  if (error)
    raise_error("reading inode metadata", error);
  inode.i_mode = type | (mode & 07777);
  inode.i_uid = uid & 0xffff;
  ext2fs_set_i_uid_high(inode, ((unsigned int)uid) >> 16);
  inode.i_gid = gid & 0xffff;
  ext2fs_set_i_gid_high(inode, ((unsigned int)gid) >> 16);
  time_t timestamp = (time_t)mtime;
  ext2fs_inode_xtime_set(&inode, i_atime, timestamp);
  ext2fs_inode_xtime_set(&inode, i_ctime, timestamp);
  ext2fs_inode_xtime_set(&inode, i_mtime, timestamp);
  error = ext2fs_write_inode(fs, ino, &inode);
  if (error)
    raise_error("writing inode metadata", error);
}

static errcode_t lookup_component(ext2_filsys fs, ext2_ino_t parent,
                                  const char *name, ext2_ino_t *ino) {
  return ext2fs_lookup(fs, parent, name, (int)strlen(name), NULL, ino);
}

static ext2_ino_t ensure_directory(ext2_filsys fs, ext2_ino_t parent,
                                   const char *name) {
  ext2_ino_t ino;
  errcode_t error = lookup_component(fs, parent, name, &ino);
  if (!error)
    return ino;
  if (error != EXT2_ET_FILE_NOT_FOUND)
    raise_error("looking up directory", error);
  error = ext2fs_mkdir(fs, parent, 0, name);
  if (error == EXT2_ET_DIR_NO_SPACE) {
    error = ext2fs_expand_dir(fs, parent);
    if (!error)
      error = ext2fs_mkdir(fs, parent, 0, name);
  }
  if (error)
    raise_error("creating directory", error);
  error = lookup_component(fs, parent, name, &ino);
  if (error)
    raise_error("looking up created directory", error);
  return ino;
}

static ext2_ino_t ensure_path_directory(ext2_filsys fs, const char *path) {
  validate_path(path);
  if (!strcmp(path, "/"))
    return EXT2_ROOT_INO;
  char *copy = strdup(path);
  if (copy == NULL)
    caml_raise_out_of_memory();
  ext2_ino_t current = EXT2_ROOT_INO;
  char *save = NULL;
  for (char *part = strtok_r(copy, "/", &save); part != NULL;
       part = strtok_r(NULL, "/", &save))
    current = ensure_directory(fs, current, part);
  free(copy);
  return current;
}

static void split_parent(const char *path, char **parent, char **name) {
  validate_path(path);
  if (!strcmp(path, "/"))
    caml_invalid_argument("Ext2fs: root has no parent");
  char *copy = strdup(path);
  if (copy == NULL)
    caml_raise_out_of_memory();
  size_t length = strlen(copy);
  while (length > 1 && copy[length - 1] == '/')
    copy[--length] = 0;
  char *slash = strrchr(copy, '/');
  *name = strdup(slash + 1);
  if (*name == NULL) {
    free(copy);
    caml_raise_out_of_memory();
  }
  if (slash == copy)
    slash[1] = 0;
  else
    *slash = 0;
  *parent = copy;
}

static void initialize_uuid(unsigned char uuid[16]) {
  int fd = open("/dev/urandom", O_RDONLY);
  ssize_t got = fd < 0 ? -1 : read(fd, uuid, 16);
  if (fd >= 0)
    close(fd);
  if (got != 16) {
    uint64_t seed = (uint64_t)time(NULL) ^ (uint64_t)getpid();
    for (int index = 0; index < 16; index++) {
      seed = seed * 6364136223846793005ULL + 1;
      uuid[index] = (unsigned char)(seed >> 56);
    }
  }
  uuid[6] = (uuid[6] & 0x0f) | 0x40;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
}

static errcode_t link_inode(ext2_filsys fs, ext2_ino_t parent,
                            const char *name, ext2_ino_t ino, int filetype) {
  errcode_t error = ext2fs_link(fs, parent, name, ino, filetype);
  if (error == EXT2_ET_DIR_NO_SPACE) {
    error = ext2fs_expand_dir(fs, parent);
    if (!error)
      error = ext2fs_link(fs, parent, name, ino, filetype);
  }
  return error;
}

CAMLprim value ash_ext2fs_create(value path_value, value size_value,
                                 value inodes_value, value label_value,
                                 value block_size_value) {
  CAMLparam5(path_value, size_value, inodes_value, label_value,
             block_size_value);
  CAMLlocal1(result);
  const char *path = String_val(path_value);
  int64_t size = Int64_val(size_value);
  int inodes = Int_val(inodes_value);
  int log_size = block_log(Int_val(block_size_value));
  int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
  if (fd < 0)
    raise_errno("creating", path);
  if (ftruncate(fd, (off_t)size) < 0) {
    int saved = errno;
    close(fd);
    unlink(path);
    errno = saved;
    raise_errno("sizing", path);
  }
  close(fd);

  struct ext2_super_block param;
  memset(&param, 0, sizeof(param));
  ext2fs_blocks_count_set(&param, (blk64_t)(size >> (10 + log_size)));
  param.s_log_block_size = log_size;
  param.s_log_cluster_size = log_size;
  param.s_rev_level = EXT2_DYNAMIC_REV;
  param.s_first_ino = EXT2_GOOD_OLD_FIRST_INO;
  param.s_inode_size = 256;
  param.s_inodes_count = (uint32_t)inodes;
  ext2fs_set_feature_filetype(&param);
  ext2fs_set_feature_sparse_super(&param);
  ext2fs_set_feature_large_file(&param);
  ext2fs_set_feature_extents(&param);
  ext2fs_set_feature_flex_bg(&param);
  ext2fs_set_feature_gdt_csum(&param);
  ext2fs_set_feature_64bit(&param);

  ext2_filsys fs = NULL;
  errcode_t error = ext2fs_initialize(path, EXT2_FLAG_64BITS, &param,
                                      unix_io_manager, &fs);
  if (error) {
    unlink(path);
    raise_error("initializing ext4 filesystem", error);
  }
  initialize_uuid(fs->super->s_uuid);
  ext2fs_init_csum_seed(fs);
  fs->super->s_mkfs_time = (uint32_t)time(NULL);
  fs->super->s_wtime = fs->super->s_mkfs_time;
  error = ext2fs_allocate_tables(fs);
  if (error) {
    ext2fs_close_free(&fs);
    unlink(path);
    raise_error("allocating ext4 tables", error);
  }
  error = ext2fs_mkdir(fs, EXT2_ROOT_INO, EXT2_ROOT_INO, NULL);
  if (error) {
    ext2fs_close_free(&fs);
    unlink(path);
    raise_error("creating ext4 root", error);
  }
  ext2fs_inode_alloc_stats2(fs, EXT2_BAD_INO, +1, 0);
  for (ext2_ino_t ino = EXT2_ROOT_INO + 1;
       ino < EXT2_FIRST_INODE(fs->super); ino++)
    ext2fs_inode_alloc_stats2(fs, ino, +1, 0);
  ext2fs_mark_ib_dirty(fs);
  fs->super->s_state = EXT2_VALID_FS;
  fs->super->s_max_mnt_count = -1;
  memset(fs->super->s_volume_name, 0, sizeof(fs->super->s_volume_name));
  strncpy((char *)fs->super->s_volume_name, String_val(label_value),
          sizeof(fs->super->s_volume_name));
  ext2fs_mark_super_dirty(fs);

  struct ash_ext2fs_handle *handle = calloc(1, sizeof(*handle));
  if (handle == NULL) {
    ext2fs_close_free(&fs);
    caml_raise_out_of_memory();
  }
  handle->fs = fs;
  handle->path = strdup(path);
  if (handle->path == NULL) {
    ext2fs_close_free(&fs);
    free(handle);
    caml_raise_out_of_memory();
  }
  result = caml_alloc_custom(&handle_ops, sizeof(handle), 0, 1);
  Handle_val(result) = handle;
  CAMLreturn(result);
}

CAMLprim value ash_ext2fs_close(value handle_value) {
  CAMLparam1(handle_value);
  close_handle(get_handle(handle_value), 1);
  CAMLreturn(Val_unit);
}

CAMLprim value ash_ext2fs_mkdir(value handle_value, value path_value,
                                value mode_value, value uid_value,
                                value gid_value, value mtime_value) {
  CAMLparam5(handle_value, path_value, mode_value, uid_value, gid_value);
  CAMLxparam1(mtime_value);
  struct ash_ext2fs_handle *handle = get_handle(handle_value);
  ext2_ino_t ino = ensure_path_directory(handle->fs, String_val(path_value));
  set_inode_metadata(handle->fs, ino, LINUX_S_IFDIR, Int_val(mode_value),
                     Int_val(uid_value), Int_val(gid_value),
                     Double_val(mtime_value));
  CAMLreturn(Val_unit);
}

CAMLprim value ash_ext2fs_mkdir_bytecode(value *argv, int argn) {
  (void)argn;
  return ash_ext2fs_mkdir(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}

CAMLprim value ash_ext2fs_write_file(value handle_value, value path_value,
                                     value source_value, value mode_value,
                                     value uid_value, value gid_value,
                                     value mtime_value) {
  CAMLparam5(handle_value, path_value, source_value, mode_value, uid_value);
  CAMLxparam2(gid_value, mtime_value);
  struct ash_ext2fs_handle *handle = get_handle(handle_value);
  const char *path = String_val(path_value);
  const char *source = String_val(source_value);
  char *parent_path = NULL;
  char *name = NULL;
  split_parent(path, &parent_path, &name);
  ext2_ino_t parent = ensure_path_directory(handle->fs, parent_path);
  free(parent_path);

  int source_fd = open(source, O_RDONLY);
  if (source_fd < 0) {
    free(name);
    raise_errno("opening source", source);
  }
  struct stat statbuf;
  if (fstat(source_fd, &statbuf) < 0) {
    int saved = errno;
    close(source_fd);
    free(name);
    errno = saved;
    raise_errno("stating source", source);
  }

  ext2_ino_t ino;
  errcode_t error = ext2fs_new_inode(handle->fs, parent,
                                     LINUX_S_IFREG | Int_val(mode_value), 0,
                                     &ino);
  if (error) {
    close(source_fd);
    free(name);
    raise_error("allocating file inode", error);
  }
  error = link_inode(handle->fs, parent, name, ino, EXT2_FT_REG_FILE);
  free(name);
  if (error) {
    close(source_fd);
    raise_error("linking file inode", error);
  }
  ext2fs_inode_alloc_stats2(handle->fs, ino, +1, 0);

  struct ext2_inode inode;
  memset(&inode, 0, sizeof(inode));
  inode.i_mode = LINUX_S_IFREG | (Int_val(mode_value) & 07777);
  inode.i_uid = Int_val(uid_value) & 0xffff;
  ext2fs_set_i_uid_high(inode, ((unsigned int)Int_val(uid_value)) >> 16);
  inode.i_gid = Int_val(gid_value) & 0xffff;
  ext2fs_set_i_gid_high(inode, ((unsigned int)Int_val(gid_value)) >> 16);
  time_t timestamp = (time_t)Double_val(mtime_value);
  ext2fs_inode_xtime_set(&inode, i_atime, timestamp);
  ext2fs_inode_xtime_set(&inode, i_ctime, timestamp);
  ext2fs_inode_xtime_set(&inode, i_mtime, timestamp);
  inode.i_links_count = 1;
  error = ext2fs_inode_size_set(handle->fs, &inode, (ext2_off64_t)statbuf.st_size);
  if (!error && ext2fs_has_feature_extents(handle->fs->super)) {
    ext2_extent_handle_t extent_handle;
    error = ext2fs_extent_open2(handle->fs, ino, &inode, &extent_handle);
    if (!error)
      ext2fs_extent_free(extent_handle);
  }
  if (!error)
    error = ext2fs_write_new_inode(handle->fs, ino, &inode);
  if (error) {
    close(source_fd);
    raise_error("initializing file inode", error);
  }

  ext2_file_t file;
  error = ext2fs_file_open(handle->fs, ino, EXT2_FILE_WRITE, &file);
  if (error) {
    close(source_fd);
    raise_error("opening ext4 file", error);
  }
  unsigned char *buffer = malloc(1024 * 1024);
  if (buffer == NULL) {
    ext2fs_file_close(file);
    close(source_fd);
    caml_raise_out_of_memory();
  }
  while (1) {
    ssize_t got = read(source_fd, buffer, 1024 * 1024);
    if (got < 0) {
      if (errno == EINTR)
        continue;
      int saved = errno;
      free(buffer);
      ext2fs_file_close(file);
      close(source_fd);
      errno = saved;
      raise_errno("reading source", source);
    }
    if (got == 0)
      break;
    size_t offset = 0;
    while (offset < (size_t)got) {
      unsigned int written = 0;
      error = ext2fs_file_write(file, buffer + offset,
                                (unsigned int)((size_t)got - offset), &written);
      if (error || written == 0) {
        free(buffer);
        ext2fs_file_close(file);
        close(source_fd);
        raise_error("writing ext4 file", error ? error : EIO);
      }
      offset += written;
    }
  }
  free(buffer);
  close(source_fd);
  error = ext2fs_file_close(file);
  if (error)
    raise_error("closing ext4 file", error);
  set_inode_metadata(handle->fs, ino, LINUX_S_IFREG, Int_val(mode_value),
                     Int_val(uid_value), Int_val(gid_value),
                     Double_val(mtime_value));
  CAMLreturn(Val_unit);
}

CAMLprim value ash_ext2fs_write_file_bytecode(value *argv, int argn) {
  (void)argn;
  return ash_ext2fs_write_file(argv[0], argv[1], argv[2], argv[3], argv[4],
                               argv[5], argv[6]);
}

CAMLprim value ash_ext2fs_symlink(value handle_value, value path_value,
                                  value target_value, value mode_value,
                                  value uid_value, value gid_value,
                                  value mtime_value) {
  CAMLparam5(handle_value, path_value, target_value, mode_value, uid_value);
  CAMLxparam2(gid_value, mtime_value);
  struct ash_ext2fs_handle *handle = get_handle(handle_value);
  char *parent_path = NULL;
  char *name = NULL;
  split_parent(String_val(path_value), &parent_path, &name);
  ext2_ino_t parent = ensure_path_directory(handle->fs, parent_path);
  free(parent_path);
  errcode_t error = ext2fs_symlink(handle->fs, parent, 0, name,
                                   String_val(target_value));
  if (error == EXT2_ET_DIR_NO_SPACE) {
    error = ext2fs_expand_dir(handle->fs, parent);
    if (!error)
      error = ext2fs_symlink(handle->fs, parent, 0, name,
                             String_val(target_value));
  }
  if (error) {
    free(name);
    raise_error("creating symlink", error);
  }
  ext2_ino_t ino;
  error = lookup_component(handle->fs, parent, name, &ino);
  free(name);
  if (error)
    raise_error("looking up symlink", error);
  set_inode_metadata(handle->fs, ino, LINUX_S_IFLNK, Int_val(mode_value),
                     Int_val(uid_value), Int_val(gid_value),
                     Double_val(mtime_value));
  CAMLreturn(Val_unit);
}

CAMLprim value ash_ext2fs_symlink_bytecode(value *argv, int argn) {
  (void)argn;
  return ash_ext2fs_symlink(argv[0], argv[1], argv[2], argv[3], argv[4],
                            argv[5], argv[6]);
}
