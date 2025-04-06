local api = vim.api
local SEPARATOR = vim.uv.os_uname().version:match('Windows') and '\\' or '/'
local FileOps = {}

-- Create file with content
FileOps.createFile = function(path, content)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      vim.uv.fs_open(path, 'w', 438, function(err, fd)
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

-- Delete directory after reading its contents
FileOps.deleteDirectory = function(path)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      local function rmdir(p)
        vim.uv.fs_scandir(p, function(err, scanner)
          if err then
            reject('Failed to scan directory: ' .. err)
            return
          end

          local function removeNext()
            local name, type = vim.uv.fs_scandir_next(scanner)
            if not name then
              -- Directory is empty, remove it
              vim.uv.fs_rmdir(p, function(rerr)
                if rerr then
                  reject('Failed to remove directory: ' .. rerr)
                  return
                end
                resolve(p)
              end)
              return
            end

            local fullpath = vim.fs.joinpath(p, name)
            if type == 'directory' then
              rmdir(fullpath) -- Recursively remove subdirectory
            else
              vim.uv.fs_unlink(fullpath, function(uerr)
                if uerr then
                  reject('Failed to remove file: ' .. uerr)
                  return
                end
                vim.schedule(removeNext)
              end)
            end
          end

          removeNext()
        end)
      end

      rmdir(path)
    end,
  }
end

-- Copy file or directory asynchronously
FileOps.copy = function(src, dest)
  return {
    kind = 'Task',
    fork = function(reject, resolve)
      -- Check if source is directory
      vim.uv.fs_stat(src, function(err, stat)
        assert(stat)
        if err then
          reject('Failed to stat source: ' .. err)
          return
        end

        if stat.type == 'directory' then
          -- Copy directory recursively
          local function copyDir(source, target)
            vim.uv.fs_mkdir(target, stat.mode, function(merr)
              if merr then
                reject('Failed to create target directory: ' .. merr)
                return
              end

              vim.uv.fs_scandir(source, function(serr, scanner)
                if serr then
                  reject('Failed to scan directory: ' .. serr)
                  return
                end

                local function copyNext()
                  local name, type = vim.uv.fs_scandir_next(scanner)
                  if not name then
                    resolve(target)
                    return
                  end

                  local sourcePath = vim.fs.joinpath(source, name)
                  local targetPath = vim.fs.joinpath(target, name)

                  if type == 'directory' then
                    copyDir(sourcePath, targetPath)
                  else
                    -- Copy file
                    vim.uv.fs_copyfile(sourcePath, targetPath, function(cerr)
                      if cerr then
                        reject('Failed to copy file: ' .. cerr)
                        return
                      end
                      vim.schedule(copyNext)
                    end)
                  end
                end

                copyNext()
              end)
            end)
          end

          copyDir(src, dest)
        else
          -- Copy single file
          vim.uv.fs_copyfile(src, dest, function(cerr)
            if cerr then
              reject('Failed to copy file: ' .. cerr)
              return
            end
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
      local sep = vim.uv.os_uname().sysname:match('Windows') and '\\' or '/'
      local parts = vim.split(path, sep, { plain = true })
      local current = ''
      local completed = 0

      local function createNext()
        if completed >= #parts - 1 then
          resolve(true)
          return
        end

        completed = completed + 1
        current = current .. parts[completed] .. sep

        if vim.fn.isdirectory(current) ~= 1 then
          FileOps.createDirectory(current).fork(reject, function()
            vim.schedule(createNext)
          end)
        else
          vim.schedule(createNext)
        end
      end

      createNext()
    end,
  }
end

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
    local search_path = lines[#lines]
    if vim.startswith(search_path, '~') then
      search_path = search_path:gsub('~', vim.env.HOME)
    end
    return search_path:match('^' .. SEPARATOR) and search_path or nil
  end,
  getSelectPath = function(state)
    return api.nvim_buf_call(state.buf, function()
      local line = api.nvim_get_current_line()
      line = line:gsub('%s+', '')
      return vim.fs.joinpath(state.current_path, line)
    end)
  end,
}

return { FileOps = FileOps, PathOps = PathOps }
