local api = vim.api
local SEPARATOR = '/'
local IS_WIN = vim.fn.has('win32') == 1
local IS_MAC = vim.fn.has('mac') == 1
local FileOps = {}

local PathOps = {
  isFile = function(path)
    local stat = vim.uv.fs_stat(path)
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

FileOps.createFile = function(path, content)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      vim.uv.fs_open(path, 'wx', 438, function(err, fd)
        if err then
          reject('Failed to create file: ' .. err)
          return
        end

        if content then
          vim.uv.fs_write(fd, content, -1, function(werr)
            vim.uv.fs_close(fd)
            if werr then
              reject('Failed to write content: ' .. werr)
              return
            end
            resolve(path)
          end)
        else
          vim.uv.fs_close(fd)
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
      vim.uv.fs_unlink(path, function(err)
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
      vim.uv.fs_mkdir(path, 493, function(err) -- 0755 permissions
        if err then
          reject('Failed to create directory: ' .. err)
          return
        end
        resolve(path)
      end)
    end,
  }
end

local function entry_type(fullpath, t)
  if t then
    return t
  end
  local st = vim.uv.fs_lstat(fullpath)
  return st and st.type or 'file'
end

-- Delete directory recursively.
FileOps.deleteDirectory = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local failed = false
      local function fail(msg)
        if not failed then
          failed = true
          reject(msg)
        end
      end

      local function rmdir(p, done)
        vim.uv.fs_scandir(p, function(err, scanner)
          if err then
            return fail('Failed to scan directory: ' .. err)
          end

          local function removeNext()
            if failed then
              return
            end
            local name, type = vim.uv.fs_scandir_next(scanner)
            if not name then
              vim.uv.fs_rmdir(p, function(rerr)
                if rerr then
                  return fail('Failed to remove directory: ' .. rerr)
                end
                done()
              end)
              return
            end

            local fullpath = vim.fs.joinpath(p, name)
            type = entry_type(fullpath, type)
            if type == 'directory' then
              rmdir(fullpath, removeNext)
            else
              vim.uv.fs_unlink(fullpath, function(uerr)
                if uerr then
                  return fail('Failed to remove file: ' .. uerr)
                end
                removeNext()
              end)
            end
          end

          removeNext()
        end)
      end

      rmdir(path, function()
        resolve(path)
      end)
    end,
  }
end

-- Copy file or directory asynchronously (same recursion fix as deleteDirectory)
FileOps.copy = function(src, dest)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local failed = false
      local function fail(msg)
        if not failed then
          failed = true
          reject(msg)
        end
      end

      local function copyFile(source, target, done)
        vim.uv.fs_copyfile(source, target, { excl = true }, function(cerr)
          if cerr then
            return fail('Failed to copy file: ' .. cerr)
          end
          done()
        end)
      end

      local function copyDir(source, target, mode, done)
        vim.uv.fs_mkdir(target, mode, function(merr)
          if merr then
            return fail('Failed to create target directory: ' .. merr)
          end
          vim.uv.fs_scandir(source, function(serr, scanner)
            if serr then
              return fail('Failed to scan directory: ' .. serr)
            end

            local function copyNext()
              if failed then
                return
              end
              local name, type = vim.uv.fs_scandir_next(scanner)
              if not name then
                return done()
              end
              local sourcePath = vim.fs.joinpath(source, name)
              local targetPath = vim.fs.joinpath(target, name)
              type = entry_type(sourcePath, type)
              if type == 'directory' then
                vim.uv.fs_stat(sourcePath, function(_, st)
                  copyDir(sourcePath, targetPath, st and st.mode or 493, copyNext)
                end)
              elseif type == 'link' then
                vim.uv.fs_readlink(sourcePath, function(lerr, link)
                  if lerr then
                    return fail('Failed to read link: ' .. lerr)
                  end
                  vim.uv.fs_symlink(link, targetPath, nil, function(yerr)
                    if yerr then
                      return fail('Failed to create link: ' .. yerr)
                    end
                    copyNext()
                  end)
                end)
              else
                copyFile(sourcePath, targetPath, copyNext)
              end
            end

            copyNext()
          end)
        end)
      end

      vim.uv.fs_lstat(src, function(err, stat)
        if err or not stat then
          return fail('Failed to stat source: ' .. tostring(err))
        end
        if stat.type == 'link' then
          vim.uv.fs_readlink(src, function(lerr, link)
            if lerr then
              return fail('Failed to read link: ' .. lerr)
            end
            vim.uv.fs_symlink(link, dest, nil, function(yerr)
              if yerr then
                return fail('Failed to create link: ' .. yerr)
              end
              resolve(dest)
            end)
          end)
        elseif stat.type == 'directory' then
          copyDir(src, dest, stat.mode, function()
            resolve(dest)
          end)
        else
          copyFile(src, dest, function()
            resolve(dest)
          end)
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
      vim.uv.fs_rename(src, dest, function(err)
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
      vim.uv.fs_rename(src, dest, function(err)
        if not err then
          return resolve(dest)
        end
        if not tostring(err):match('EXDEV') then
          return reject('Failed to move/rename: ' .. err)
        end
        FileOps.copy(src, dest).fork(reject, function()
          vim.uv.fs_lstat(src, function(_, st)
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
      vim.uv.fs_open(path, 'r', 438, function(err, fd)
        if err then
          reject('Failed to open file: ' .. err)
          return
        end

        vim.uv.fs_read(fd, maxBytes or 1024, 0, function(rerr, data)
          vim.uv.fs_close(fd)
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

local function trash_command(path)
  if IS_MAC then
    if vim.fn.executable('/usr/bin/trash') == 1 then
      return { '/usr/bin/trash', path }
    end
    local escaped = path:gsub('\\', '\\\\'):gsub('"', '\\"')
    return {
      'osascript',
      '-e',
      ('tell application "Finder" to delete POSIX file "%s"'):format(escaped),
    }
  elseif IS_WIN then
    local p = path:gsub('/', '\\'):gsub("'", "''")
    local stat = vim.uv.fs_lstat(path)
    local fn = (stat and stat.type == 'directory') and 'DeleteDirectory' or 'DeleteFile'
    return {
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      ("Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::%s('%s', 'OnlyErrorDialogs', 'SendToRecycleBin')"):format(
        fn,
        p
      ),
    }
  else
    for _, c in ipairs({ { 'gio', 'trash' }, { 'trash-put' }, { 'trash' }, { 'kioclient', 'move' } }) do
      if vim.fn.executable(c[1]) == 1 then
        local cmd = vim.list_extend(vim.deepcopy(c), { path })
        if c[1] == 'kioclient' then
          table.insert(cmd, 'trash:/')
        end
        return cmd
      end
    end
    return nil,
      'No trash command found. Please install gio, trash-cli or kioclient, or set use_trash = false.'
  end
end

FileOps.moveToTrash = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      if not vim.uv.fs_lstat(path) then
        reject('File or directory not found: ' .. path)
        return
      end
      local cmd, err = trash_command(path)
      if not cmd then
        reject(err)
        return
      end
      local ok, sys_err = pcall(
        vim.system,
        cmd,
        { text = true },
        vim.schedule_wrap(function(obj)
          if obj.code == 0 and not vim.uv.fs_lstat(path) then
            resolve()
          elseif obj.code == 0 then
            reject('Trash command reported success but file still exists')
          else
            local err_msg = obj.stderr or ''
            if err_msg:match('^%s*$') then
              err_msg = 'Command failed with exit code: ' .. obj.code
            end
            reject(err_msg)
          end
        end)
      )
      if not ok then
        reject(tostring(sys_err))
      end
    end,
  }
end

return { FileOps = FileOps, PathOps = PathOps }
