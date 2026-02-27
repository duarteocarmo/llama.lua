--- Server lifecycle management for llama-server
--- Automatically starts llama-server if not already running, reuses across Neovim instances.
local debug = require("llama.debug")

local M = {}

M.job_id = nil
M.pid = nil

--- Extract port from an endpoint URL
---@param endpoint string
---@return number
local function port_from_endpoint(endpoint)
  local port = endpoint:match(":(%d+)")
  return tonumber(port) or 8012
end

--- Check if something is already listening on a port
---@param port number
---@return boolean
local function port_in_use(port)
  local result = vim.fn.system("lsof -ti:" .. port)
  return result:match("%d+") ~= nil
end

--- Start the server if not already running
---@param config table
function M.start(config)
  local port = port_from_endpoint(config.endpoint_fim)

  if port_in_use(port) then
    debug.log("server", "already running on :" .. port)
    vim.notify("llama-server already running on :" .. port, vim.log.levels.INFO)
    return
  end

  if vim.fn.executable("llama-server") ~= 1 then
    vim.notify("llama-server not found in PATH — install llama.cpp first", vim.log.levels.ERROR)
    return
  end

  local cmd = { "llama-server", "--port", tostring(port) }

  -- append server args (e.g. "--fim-qwen-7b-default" or {"--model", "/path/to/model.gguf"})
  local args = config.server_args or {}
  if type(args) == "string" then
    args = { args }
  end
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  debug.log("server", "starting: " .. table.concat(cmd, " "))

  M.job_id = vim.fn.jobstart(cmd, {
    detach = true,
    on_exit = function(_, code, _)
      if code ~= 0 and code ~= 143 then -- 143 = SIGTERM, normal shutdown
        vim.schedule(function()
          vim.notify("llama-server exited with code " .. code, vim.log.levels.WARN)
        end)
      end
      M.job_id = nil
      M.pid = nil
    end,
  })

  if M.job_id and M.job_id > 0 then
    M.pid = vim.fn.jobpid(M.job_id)
    vim.notify("llama-server started (pid " .. M.pid .. ", port " .. port .. ")", vim.log.levels.INFO)
    debug.log("server", "pid " .. M.pid)
  else
    vim.notify("failed to start llama-server", vim.log.levels.ERROR)
    M.job_id = nil
  end
end

--- Stop the server only if we started it
function M.stop()
  if not M.pid then
    return
  end

  debug.log("server", "stopping pid " .. M.pid)
  vim.fn.jobstop(M.job_id)
  M.job_id = nil
  M.pid = nil
end

--- Setup VimLeavePre autocmd to clean up on exit
---@param config table
function M.setup(config)
  if not config.server_managed then
    return
  end

  M.start(config)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("llama_server", { clear = true }),
    callback = function()
      M.stop()
    end,
  })
end

return M
