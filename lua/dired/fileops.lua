-- Enhanced File operations using vim.uv async functions
local M = {}
-- Create file with content
M.createFile = function(path, content)
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
M.deleteFile = function(path)
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
M.createDirectory = function(path)
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
M.deleteDirectory = function(path)
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
M.copy = function(src, dest)
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
M.move = function(src, dest)
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
M.readFile = function(path, maxBytes)
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

return M
