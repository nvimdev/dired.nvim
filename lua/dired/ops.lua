local api = vim.api
local uv = vim.uv
local bit = require('bit')
local SEPARATOR = '/'
local IS_WIN = vim.fn.has('win32') == 1
local IS_MAC = vim.fn.has('mac') == 1
local FileOps = {}

-- Max concurrent libuv fs requests for recursive copy/delete. libuv's threadpool
-- defaults to 4 threads; keeping a few dozen requests queued keeps it saturated
-- instead of paying a full event-loop round trip per file.
local MAX_INFLIGHT = 32

local PathOps = {
  isFile = function(path)
    local stat = uv.fs_stat(path)
    return stat and stat.type == 'file'
  end,

  isDirectory = function(path)
    return vim.fn.isdirectory(path) == 1
  end,

  getSearchPath = function(state)
    local lines = api.nvim_buf_get_lines(state.search_buf, 0, -1, false)
    local search_path = lines[#lines] or ''
    if
      not (
        vim.startswith(search_path, '~')
        or vim.startswith(search_path, '/')
        or search_path:match('^%a:[\\/]')
      )
    then
      return nil
    end
    local trailing = search_path:match('[/\\]$') and SEPARATOR or ''
    local normalized = vim.fs.normalize(search_path)
    if not vim.endswith(normalized, SEPARATOR) then
      normalized = normalized .. trailing
    end
    return normalized
  end,
  getSelectPath = function(state)
    local lnum = api.nvim_win_get_cursor(state.win)[1]
    local line = api.nvim_buf_get_lines(state.buf, lnum - 1, lnum, false)[1] or ''
    return vim.fs.joinpath(state.current_path, vim.trim(line))
  end,
}

-- Plain string helpers (safe in luv callbacks, unlike anything touching vim.fn).
local function join(dir, name)
  if dir:sub(-1) == '/' then
    return dir .. name
  end
  return dir .. '/' .. name
end

local function is_inside(child, parent)
  parent = parent:gsub('/+$', '')
  return child:sub(1, #parent + 1) == parent .. '/'
end

local function same_inode(a, b)
  return a and b and a.ino == b.ino and a.dev == b.dev
end

local function entry_type(fullpath, t)
  if t then
    return t
  end
  local st = uv.fs_lstat(fullpath)
  return st and st.type or 'file'
end

-- Bounded job queue. A job receives `release` and must call it exactly once.
-- The `pumping` guard turns synchronous releases into loop iterations, so a
-- burst of immediate failures cannot grow the C stack.
local function limiter(limit)
  local active, head, tail, queue, pumping = 0, 1, 0, {}, false
  local self = {}
  local function release()
    active = active - 1
    self.pump()
  end
  function self.pump()
    if pumping then
      return
    end
    pumping = true
    while active < limit and head <= tail do
      local job = queue[head]
      queue[head] = nil
      head = head + 1
      active = active + 1
      job(release)
    end
    pumping = false
  end
  function self.run(job)
    tail = tail + 1
    queue[tail] = job
    self.pump()
  end
  function self.cancel()
    for i = head, tail do
      queue[i] = nil
    end
    head = tail + 1
  end
  return self
end

-- Run one async uv.fs_* call inside a limiter slot. The trailing callback fires
-- exactly once, also when luv fails synchronously (returns nil, no callback).
local function fs(pool, method, ...)
  local n = select('#', ...)
  local args = { ... }
  local cb = args[n]
  pool.run(function(release)
    local fired = false
    args[n] = function(...)
      if fired then
        return
      end
      fired = true
      release()
      cb(...)
    end
    local ok, req, err = pcall(uv[method], unpack(args, 1, n))
    if not ok or not req then
      args[n](tostring(not ok and req or err or ('uv.' .. method .. ' failed')))
    end
  end)
end

FileOps.createFile = function(path, content)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      uv.fs_open(path, 'wx', 438, function(err, fd)
        if err then
          reject('Failed to create file: ' .. err)
          return
        end

        if content then
          uv.fs_write(fd, content, -1, function(werr)
            uv.fs_close(fd)
            if werr then
              reject('Failed to write content: ' .. werr)
              return
            end
            resolve(path)
          end)
        else
          uv.fs_close(fd)
          resolve(path)
        end
      end)
    end,
  }
end

-- Delete file using async fs_unlink
FileOps.deleteFile = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      uv.fs_unlink(path, function(err)
        if err then
          reject('Failed to delete file: ' .. err)
          return
        end
        resolve(path)
      end)
    end,
  }
end

-- Create directory with proper permissions
FileOps.createDirectory = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      uv.fs_mkdir(path, 493, function(err) -- 0755 permissions
        if err then
          reject('Failed to create directory: ' .. err)
          return
        end
        resolve(path)
      end)
    end,
  }
end

-- Delete a directory tree with bounded parallelism.
FileOps.deleteDirectory = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      -- Never recurse through a symlink: fs_scandir follows links, so treating a
      -- link-to-directory as a directory would wipe the *target's* contents.
      local st = uv.fs_lstat(path)
      if not st then
        return reject('Failed to delete: no such file or directory: ' .. path)
      end
      if st.type ~= 'directory' then
        return FileOps.deleteFile(path).fork(reject, resolve)
      end

      local pool = limiter(MAX_INFLIGHT)
      local failed = false
      local function fail(msg)
        if not failed then
          failed = true
          pool.cancel()
          reject(msg)
        end
      end

      local function rmtree(dir, done)
        fs(pool, 'fs_scandir', dir, function(err, scanner)
          if failed then
            return
          end
          if err then
            return fail('Failed to scan directory: ' .. err)
          end
          local pending = 1 -- guard so `done` can't fire before the scan loop ends
          local function child_done()
            pending = pending - 1
            if pending == 0 and not failed then
              fs(pool, 'fs_rmdir', dir, function(rerr)
                if rerr then
                  return fail('Failed to remove directory: ' .. rerr)
                end
                done()
              end)
            end
          end
          while true do
            local name, t = uv.fs_scandir_next(scanner)
            if not name then
              break
            end
            pending = pending + 1
            local full = join(dir, name)
            if entry_type(full, t) == 'directory' then
              rmtree(full, child_done)
            else
              fs(pool, 'fs_unlink', full, function(uerr)
                if uerr then
                  return fail('Failed to remove file: ' .. uerr)
                end
                child_done()
              end)
            end
          end
          child_done()
        end)
      end

      rmtree(path, function()
        resolve(path)
      end)
    end,
  }
end

-- ficlone: copy-on-write clone where supported (btrfs/XFS/APFS), silent
-- fallback to a normal copy elsewhere.
local COPY_FLAGS = { excl = true, ficlone = true }

-- Copy file or directory tree with bounded parallelism.
FileOps.copy = function(src, dest)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local pool = limiter(MAX_INFLIGHT)
      local failed = false
      local function fail(msg)
        if not failed then
          failed = true
          pool.cancel()
          reject(msg)
        end
      end

      local function copy_link(s, d, done)
        fs(pool, 'fs_readlink', s, function(lerr, link)
          if lerr then
            return fail('Failed to read link: ' .. lerr)
          end
          fs(pool, 'fs_symlink', link, d, nil, function(yerr)
            if yerr then
              return fail('Failed to create link: ' .. yerr)
            end
            done()
          end)
        end)
      end

      local function copy_file(s, d, done)
        fs(pool, 'fs_copyfile', s, d, COPY_FLAGS, function(cerr)
          if cerr then
            return fail('Failed to copy file: ' .. cerr)
          end
          done()
        end)
      end

      local copy_dir
      copy_dir = function(s, d, mode, done)
        local perm = bit.band(mode or 493, 511) -- 0777, drops the file-type bits
        local owner_rwx = bit.band(perm, 448) == 448 -- 0700
        -- Create it owner-writable so read-only source dirs can still be filled;
        -- the real mode is applied once the children are in.
        fs(pool, 'fs_mkdir', d, bit.bor(perm, 448), function(merr)
          if failed then
            return
          end
          if merr then
            return fail('Failed to create target directory: ' .. merr)
          end
          fs(pool, 'fs_scandir', s, function(serr, scanner)
            if failed then
              return
            end
            if serr then
              return fail('Failed to scan directory: ' .. serr)
            end
            local pending = 1
            local function child_done()
              pending = pending - 1
              if pending ~= 0 or failed then
                return
              end
              if owner_rwx then
                return done()
              end
              fs(pool, 'fs_chmod', d, perm, function(cherr)
                if cherr then
                  return fail('Failed to set permissions: ' .. cherr)
                end
                done()
              end)
            end
            while true do
              local name, t = uv.fs_scandir_next(scanner)
              if not name then
                break
              end
              local sp, dp = join(s, name), join(d, name)
              t = entry_type(sp, t)
              if t == 'directory' then
                pending = pending + 1
                fs(pool, 'fs_lstat', sp, function(_, st)
                  if not failed then
                    copy_dir(sp, dp, st and st.mode, child_done)
                  end
                end)
              elseif t == 'link' then
                pending = pending + 1
                copy_link(sp, dp, child_done)
              elseif t == 'file' then
                pending = pending + 1
                copy_file(sp, dp, child_done)
              end
              -- fifo/socket/char/block are skipped: fs_copyfile on a FIFO blocks a
              -- threadpool thread forever.
            end
            child_done()
          end)
        end)
      end

      local function finish()
        resolve(dest)
      end

      uv.fs_lstat(src, function(err, stat)
        if err or not stat then
          return fail('Failed to stat source: ' .. tostring(err))
        end
        if stat.type == 'link' then
          copy_link(src, dest, finish)
        elseif stat.type == 'directory' then
          if is_inside(dest, src) then
            return fail('Cannot copy a directory into itself: ' .. dest)
          end
          copy_dir(src, dest, stat.mode, finish)
        elseif stat.type == 'file' then
          copy_file(src, dest, finish)
        else
          fail('Unsupported file type: ' .. stat.type)
        end
      end)
    end,
  }
end

-- Move/rename using async fs_rename
FileOps.move = function(src, dest)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      uv.fs_rename(src, dest, function(err)
        if err then
          reject('Failed to move/rename: ' .. err)
          return
        end
        resolve(dest)
      end)
    end,
  }
end

FileOps.moveAcross = function(src, dest)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      -- fs_rename silently replaces an existing file. Refuse instead; a case-only
      -- rename on a case-insensitive FS resolves to the same inode and is allowed.
      local dst = uv.fs_lstat(dest)
      if dst and not same_inode(uv.fs_lstat(src), dst) then
        return reject('Target already exists: ' .. dest)
      end
      uv.fs_rename(src, dest, function(err)
        if not err then
          return resolve(dest)
        end
        if not tostring(err):match('EXDEV') then
          return reject('Failed to move/rename: ' .. err)
        end
        FileOps.copy(src, dest).fork(function(cerr)
          -- dest did not exist before, so everything there is our partial copy
          local st = uv.fs_lstat(dest)
          if not st then
            return reject(cerr)
          end
          local undo = st.type == 'directory' and FileOps.deleteDirectory(dest)
            or FileOps.deleteFile(dest)
          undo.fork(function()
            reject(cerr .. ' (partial copy left at ' .. dest .. ')')
          end, function()
            reject(cerr)
          end)
        end, function()
          uv.fs_lstat(src, function(_, st)
            local is_dir = st and st.type == 'directory'
            local del = is_dir and FileOps.deleteDirectory(src) or FileOps.deleteFile(src)
            del.fork(function(derr)
              reject('Copied but failed to remove source: ' .. derr)
            end, function()
              resolve(dest)
            end)
          end)
        end)
      end)
    end,
  }
end

-- Read file content for preview
FileOps.readFile = function(path, maxBytes)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      uv.fs_open(path, 'r', 438, function(err, fd)
        if err then
          reject('Failed to open file: ' .. err)
          return
        end

        uv.fs_read(fd, maxBytes or 1024, 0, function(rerr, data)
          uv.fs_close(fd)
          if rerr then
            reject('Failed to read file: ' .. rerr)
            return
          end
          resolve(data)
        end)
      end)
    end,
  }
end

FileOps.createDirectoryTree = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      vim.schedule(function()
        if vim.fn.isdirectory(path) == 1 or vim.fn.mkdir(path, 'p') == 1 then
          resolve(true)
        else
          reject('Failed to create directory tree: ' .. path)
        end
      end)
    end,
  }
end

-- Build one trash command for a batch of paths. Every backend below accepts
-- several paths per invocation, which matters most on Windows where each
-- powershell.exe start costs hundreds of milliseconds.
local function trash_command(paths)
  if IS_MAC then
    if vim.fn.executable('/usr/bin/trash') == 1 then
      return vim.list_extend({ '/usr/bin/trash' }, paths)
    end
    local files = {}
    for i, p in ipairs(paths) do
      files[i] = ('POSIX file "%s"'):format((p:gsub('\\', '\\\\'):gsub('"', '\\"')))
    end
    return {
      'osascript',
      '-e',
      ('tell application "Finder" to delete {%s}'):format(table.concat(files, ', ')),
    }
  elseif IS_WIN then
    local stmts = { 'Add-Type -AssemblyName Microsoft.VisualBasic' }
    for _, path in ipairs(paths) do
      local p = path:gsub('/', '\\'):gsub("'", "''")
      local stat = uv.fs_lstat(path)
      local fn = (stat and stat.type == 'directory') and 'DeleteDirectory' or 'DeleteFile'
      stmts[#stmts + 1] = ("[Microsoft.VisualBasic.FileIO.FileSystem]::%s('%s', 'OnlyErrorDialogs', 'SendToRecycleBin')"):format(
        fn,
        p
      )
    end
    return {
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      table.concat(stmts, '; '),
    }
  else
    for _, c in ipairs({
      { 'gio', 'trash' },
      { 'trash-put' },
      { 'trash' },
      { 'kioclient', 'move' },
      { 'kioclient5', 'move' },
    }) do
      if vim.fn.executable(c[1]) == 1 then
        local cmd = vim.list_extend(vim.list_extend({}, c), paths)
        if c[1]:find('^kioclient') then
          table.insert(cmd, 'trash:/')
        end
        return cmd
      end
    end
    return nil,
      'No trash command found. Please install gio, trash-cli or kioclient, or set use_trash = false.'
  end
end

-- Move one path or a list of paths to the trash, in as few processes as possible.
-- Success is judged by whether the paths are gone, not by exit codes alone.
FileOps.moveToTrash = function(paths)
  if type(paths) == 'string' then
    paths = { paths }
  end
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local missing = {}
      for _, p in ipairs(paths) do
        if not uv.fs_lstat(p) then
          missing[#missing + 1] = p
        end
      end
      if #missing > 0 then
        return reject('File or directory not found: ' .. table.concat(missing, ', '))
      end

      local chunk = IS_WIN and 20 or 200 -- keep Windows under its command-line limit
      local idx, stderr = 1, {}

      local function finish()
        local left = {}
        for _, p in ipairs(paths) do
          if uv.fs_lstat(p) then
            left[#left + 1] = p
          end
        end
        if #left == 0 then
          return resolve()
        end
        local msg = #stderr > 0 and table.concat(stderr, '\n')
          or 'Trash command reported success but file still exists'
        reject(('%s\nnot trashed: %s'):format(msg, table.concat(left, ', ')))
      end

      local function step()
        if idx > #paths then
          return finish()
        end
        local batch = vim.list_slice(paths, idx, idx + chunk - 1)
        idx = idx + chunk
        local cmd, err = trash_command(batch)
        if not cmd then
          return reject(err)
        end
        local ok, sys_err = pcall(
          vim.system,
          cmd,
          { text = true },
          vim.schedule_wrap(function(obj)
            if obj.code ~= 0 then
              local e = obj.stderr or ''
              if e:match('^%s*$') then
                e = 'Command failed with exit code: ' .. obj.code
              end
              stderr[#stderr + 1] = e
            end
            step()
          end)
        )
        if not ok then
          reject(tostring(sys_err))
        end
      end

      step()
    end,
  }
end

return { FileOps = FileOps, PathOps = PathOps }
