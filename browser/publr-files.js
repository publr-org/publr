// The project's files for the Publr module: kept in OPFS under `files/`, the folder the
// module runs in (WASI's fd 3), and mirrored in memory because WASI's calls are synchronous
// while OPFS is not. What a request writes reaches OPFS before its response does.

const PublrFiles = (() => {
  const root_name = "files";
  const errno = { success: 0, badf: 8, exist: 20, inval: 28, isdir: 31, nosys: 52, noent: 44, notdir: 54, notempty: 55 };
  const filetype = { character_device: 2, directory: 3, regular_file: 4 };
  const oflag = { creat: 1, directory: 2, excl: 4, trunc: 8 };
  const fdflag_append = 1;
  const rights_all = 0xffffffffffffffffn;
  const cwd = 3;

  const files = new Map();
  const folders = new Set([""]);
  const changed = new Set();
  const inodes = new Map();
  const open = new Map([[cwd, { path: "", folder: true }]]);
  let next_fd = cwd + 1;
  let memory = null;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function parent_of(path) {
    const slash = path.lastIndexOf("/");
    return slash < 0 ? "" : path.slice(0, slash);
  }

  function inode_of(path) {
    if (!inodes.has(path)) inodes.set(path, BigInt(inodes.size + 1));
    return inodes.get(path);
  }

  function children_of(folder) {
    const prefix = folder ? folder + "/" : "";
    const names = new Map();
    for (const path of folders) {
      if (path && parent_of(path) === folder) names.set(path.slice(prefix.length), filetype.directory);
    }
    for (const path of files.keys()) {
      if (parent_of(path) === folder) names.set(path.slice(prefix.length), filetype.regular_file);
    }
    return [...names].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  }

  function add_folders(path) {
    for (let folder = parent_of(path); folder && !folders.has(folder); folder = parent_of(folder)) {
      folders.add(folder);
      changed.add(folder);
    }
  }

  function bytes(ptr, len) {
    return new Uint8Array(memory().buffer, ptr, len);
  }

  function view() {
    return new DataView(memory().buffer);
  }

  // A path below `fd`'s folder, without `.` and `..`; null when it leaves the project.
  function resolve(fd, ptr, len) {
    const base = open.get(fd);
    if (!base || !base.folder) return null;
    const parts = base.path ? base.path.split("/") : [];
    for (const part of decoder.decode(bytes(ptr, len)).split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") {
        if (parts.length === 0) return null;
        parts.pop();
        continue;
      }
      parts.push(part);
    }
    return parts.join("/");
  }

  function write_stat(ptr, path) {
    const folder = folders.has(path);
    const data = view();
    const now = BigInt(Date.now()) * 1000000n;
    data.setBigUint64(ptr, 0n, true);
    data.setBigUint64(ptr + 8, inode_of(path), true);
    data.setUint8(ptr + 16, folder ? filetype.directory : filetype.regular_file);
    data.setBigUint64(ptr + 24, 1n, true);
    data.setBigUint64(ptr + 32, folder ? 0n : BigInt(files.get(path).length), true);
    for (const offset of [40, 48, 56]) data.setBigUint64(ptr + offset, now, true);
  }

  function gather(iovs, count) {
    const data = view();
    const parts = [];
    for (let index = 0; index < count; index += 1) {
      const ptr = data.getUint32(iovs + index * 8, true);
      const len = data.getUint32(iovs + index * 8 + 4, true);
      parts.push(bytes(ptr, len).slice());
    }
    return parts;
  }

  function scatter(iovs, count, source) {
    const data = view();
    let done = 0;
    for (let index = 0; index < count && done < source.length; index += 1) {
      const ptr = data.getUint32(iovs + index * 8, true);
      const len = data.getUint32(iovs + index * 8 + 4, true);
      const piece = source.subarray(done, done + len);
      bytes(ptr, piece.length).set(piece);
      done += piece.length;
    }
    return done;
  }

  function write_at(path, offset, parts) {
    const total = parts.reduce((sum, part) => sum + part.length, 0);
    let content = files.get(path);
    if (offset + total > content.length) {
      const grown = new Uint8Array(offset + total);
      grown.set(content);
      content = grown;
    }
    let at = offset;
    for (const part of parts) {
      content.set(part, at);
      at += part.length;
    }
    files.set(path, content);
    changed.add(path);
    return total;
  }

  function file_of(fd) {
    const entry = open.get(fd);
    return entry && !entry.folder && files.has(entry.path) ? entry : null;
  }

  function remove_tree(path) {
    for (const file of [...files.keys()]) if (file === path || file.startsWith(path + "/")) files.delete(file);
    for (const folder of [...folders]) if (folder === path || folder.startsWith(path + "/")) folders.delete(folder);
    changed.add(path);
  }

  const wasi = {
    path_open(fd, _lookup, path_ptr, path_len, oflags, _base, _inheriting, fdflags, fd_out) {
      const path = resolve(fd, path_ptr, path_len);
      if (path === null) return errno.noent;
      const folder = folders.has(path);
      if (oflags & oflag.directory && !folder) return files.has(path) ? errno.notdir : errno.noent;
      if (!folder && !files.has(path)) {
        if (!(oflags & oflag.creat)) return errno.noent;
        if (!folders.has(parent_of(path))) return errno.noent;
        files.set(path, new Uint8Array(0));
        changed.add(path);
      } else if (oflags & oflag.creat && oflags & oflag.excl) {
        return errno.exist;
      } else if (!folder && oflags & oflag.trunc) {
        files.set(path, new Uint8Array(0));
        changed.add(path);
      }
      const opened = next_fd;
      next_fd += 1;
      open.set(opened, { path, folder, position: 0, append: (fdflags & fdflag_append) !== 0 });
      view().setUint32(fd_out, opened, true);
      return errno.success;
    },
    fd_close(fd) {
      if (fd > cwd) open.delete(fd);
      return errno.success;
    },
    fd_read(fd, iovs, count, read_out) {
      if (fd === 0) {
        view().setUint32(read_out, 0, true);
        return errno.success;
      }
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      const done = scatter(iovs, count, files.get(entry.path).subarray(entry.position));
      entry.position += done;
      view().setUint32(read_out, done, true);
      return errno.success;
    },
    fd_pread(fd, iovs, count, offset, read_out) {
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      const done = scatter(iovs, count, files.get(entry.path).subarray(Number(offset)));
      view().setUint32(read_out, done, true);
      return errno.success;
    },
    fd_write(fd, iovs, count, written_out) {
      const parts = gather(iovs, count);
      if (fd === 1 || fd === 2) {
        const text = parts.map((part) => decoder.decode(part)).join("");
        if (text.trim()) console.log("[publr]", text.trimEnd());
        view().setUint32(written_out, parts.reduce((sum, part) => sum + part.length, 0), true);
        return errno.success;
      }
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      const at = entry.append ? files.get(entry.path).length : entry.position;
      const done = write_at(entry.path, at, parts);
      entry.position = at + done;
      view().setUint32(written_out, done, true);
      return errno.success;
    },
    fd_pwrite(fd, iovs, count, offset, written_out) {
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      view().setUint32(written_out, write_at(entry.path, Number(offset), gather(iovs, count)), true);
      return errno.success;
    },
    fd_seek(fd, offset, whence, position_out) {
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      const base = [0, entry.position, files.get(entry.path).length][whence];
      if (base === undefined || base + Number(offset) < 0) return errno.inval;
      entry.position = base + Number(offset);
      view().setBigUint64(position_out, BigInt(entry.position), true);
      return errno.success;
    },
    fd_filestat_get(fd, stat_out) {
      const entry = open.get(fd);
      if (!entry) return errno.badf;
      write_stat(stat_out, entry.path);
      return errno.success;
    },
    path_filestat_get(fd, _lookup, path_ptr, path_len, stat_out) {
      const path = resolve(fd, path_ptr, path_len);
      if (path === null || (!folders.has(path) && !files.has(path))) return errno.noent;
      write_stat(stat_out, path);
      return errno.success;
    },
    fd_fdstat_get(fd, stat_out) {
      const entry = open.get(fd);
      if (fd > 2 && !entry) return errno.badf;
      const data = view();
      const type = fd <= 2 ? filetype.character_device : entry.folder ? filetype.directory : filetype.regular_file;
      data.setUint8(stat_out, type);
      data.setUint16(stat_out + 2, entry?.append ? fdflag_append : 0, true);
      data.setBigUint64(stat_out + 8, rights_all, true);
      data.setBigUint64(stat_out + 16, rights_all, true);
      return errno.success;
    },
    fd_prestat_get(fd, prestat_out) {
      if (fd !== cwd) return errno.badf;
      view().setUint8(prestat_out, 0);
      view().setUint32(prestat_out + 4, 1, true);
      return errno.success;
    },
    fd_prestat_dir_name(fd, path_ptr, path_len) {
      if (fd !== cwd || path_len < 1) return errno.badf;
      bytes(path_ptr, 1).set(encoder.encode("."));
      return errno.success;
    },
    // Each entry is a 24-byte dirent and its name; the buffer is filled even if that cuts the
    // last one, which tells the caller to ask again with a larger one.
    fd_readdir(fd, buffer, buffer_len, cookie, used_out) {
      const entry = open.get(fd);
      if (!entry || !entry.folder) return errno.notdir;
      const pieces = [];
      children_of(entry.path).slice(Number(cookie)).forEach(([name, type], index) => {
        const encoded = encoder.encode(name);
        const piece = new Uint8Array(24 + encoded.length);
        const data = new DataView(piece.buffer);
        data.setBigUint64(0, cookie + BigInt(index + 1), true);
        data.setBigUint64(8, inode_of(entry.path ? `${entry.path}/${name}` : name), true);
        data.setUint32(16, encoded.length, true);
        data.setUint8(20, type);
        piece.set(encoded, 24);
        pieces.push(piece);
      });
      let used = 0;
      for (const piece of pieces) {
        const room = buffer_len - used;
        if (room <= 0) break;
        bytes(buffer + used, Math.min(room, piece.length)).set(piece.subarray(0, room));
        used += Math.min(room, piece.length);
      }
      view().setUint32(used_out, used, true);
      return errno.success;
    },
    path_create_directory(fd, path_ptr, path_len) {
      const path = resolve(fd, path_ptr, path_len);
      if (path === null || path === "") return errno.exist;
      if (folders.has(path) || files.has(path)) return errno.exist;
      if (!folders.has(parent_of(path))) return errno.noent;
      folders.add(path);
      changed.add(path);
      return errno.success;
    },
    path_unlink_file(fd, path_ptr, path_len) {
      const path = resolve(fd, path_ptr, path_len);
      if (path !== null && folders.has(path)) return errno.isdir;
      if (path === null || !files.has(path)) return errno.noent;
      files.delete(path);
      changed.add(path);
      return errno.success;
    },
    path_remove_directory(fd, path_ptr, path_len) {
      const path = resolve(fd, path_ptr, path_len);
      if (path !== null && files.has(path)) return errno.notdir;
      if (path === null || path === "" || !folders.has(path)) return errno.noent;
      if (children_of(path).length > 0) return errno.notempty;
      folders.delete(path);
      changed.add(path);
      return errno.success;
    },
    path_rename(fd, old_ptr, old_len, new_fd, new_ptr, new_len) {
      const from = resolve(fd, old_ptr, old_len);
      const to = resolve(new_fd, new_ptr, new_len);
      if (from === null || to === null || (!files.has(from) && !folders.has(from))) return errno.noent;
      if (!folders.has(parent_of(to))) return errno.noent;
      if (files.has(from)) {
        files.set(to, files.get(from));
        files.delete(from);
      } else {
        for (const folder of [...folders]) {
          if (folder === from || folder.startsWith(from + "/")) folders.add(to + folder.slice(from.length));
        }
        for (const [file, content] of [...files]) {
          if (file.startsWith(from + "/")) files.set(to + file.slice(from.length), content);
        }
        remove_tree(from);
      }
      changed.add(from);
      changed.add(to);
      for (const path of [...files.keys(), ...folders]) if (path.startsWith(to + "/")) changed.add(path);
      return errno.success;
    },
    fd_filestat_set_size(fd, size) {
      const entry = file_of(fd);
      if (!entry) return errno.badf;
      const resized = new Uint8Array(Number(size));
      resized.set(files.get(entry.path).subarray(0, resized.length));
      files.set(entry.path, resized);
      changed.add(entry.path);
      return errno.success;
    },
    fd_sync: () => errno.success,
    fd_datasync: () => errno.success,
    fd_fdstat_set_flags: () => errno.success,
    fd_filestat_set_times: () => errno.success,
    path_filestat_set_times: () => errno.success,
    path_readlink: () => errno.inval,
  };

  async function root_folder() {
    return (await navigator.storage.getDirectory()).getDirectoryHandle(root_name, { create: true });
  }

  async function read_folder(handle, prefix) {
    for await (const [name, child] of handle.entries()) {
      const path = prefix ? `${prefix}/${name}` : name;
      if (child.kind === "directory") {
        folders.add(path);
        await read_folder(child, path);
      } else {
        files.set(path, new Uint8Array(await (await child.getFile()).arrayBuffer()));
      }
    }
  }

  async function folder_handle(path, create) {
    let handle = await root_folder();
    for (const part of path ? path.split("/") : []) handle = await handle.getDirectoryHandle(part, { create });
    return handle;
  }

  return {
    wasi,

    // What OPFS holds, read into memory; a browser with none starts from `seed_url`, a JSON
    // object of paths and their contents in base64.
    async load(memory_of, seed_url) {
      memory = memory_of;
      await read_folder(await root_folder(), "");
      if (files.size > 0 || !seed_url) return;
      const response = await fetch(seed_url);
      if (!response.ok) throw new Error(`The seed files ${seed_url} could not be fetched: ${response.status}`);
      for (const [path, base64] of Object.entries(await response.json())) {
        files.set(path, Uint8Array.from(atob(base64), (character) => character.charCodeAt(0)));
        changed.add(path);
        add_folders(path);
      }
      await this.flush();
    },

    // Every change since the last flush, carried out in OPFS: written, made or removed.
    async flush() {
      const paths = [...changed].sort((a, b) => a.split("/").length - b.split("/").length);
      changed.clear();
      for (const path of paths) {
        const kept = files.has(path) || folders.has(path);
        const parent = await folder_handle(parent_of(path), kept).catch(() => null);
        const name = path.slice(path.lastIndexOf("/") + 1);
        if (!parent) continue;
        if (files.has(path)) {
          const writable = await (await parent.getFileHandle(name, { create: true })).createWritable();
          await writable.write(files.get(path));
          await writable.close();
        } else if (folders.has(path)) {
          await parent.getDirectoryHandle(name, { create: true });
        } else {
          await parent.removeEntry(name, { recursive: true }).catch(() => {});
        }
      }
    },
  };
})();
