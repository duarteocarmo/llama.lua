local M = {}

M.enabled = false
M.log_buf = nil
M.log_win = nil
M.entries = {}

function M.log(msg, detail)
  if not M.enabled then
    return
  end

  local entry = os.date("%H:%M:%S") .. " | " .. msg
  if detail then
    entry = entry .. " | " .. tostring(detail)
  end
  table.insert(M.entries, entry)

  if M.log_buf and vim.api.nvim_buf_is_valid(M.log_buf) then
    vim.api.nvim_buf_set_lines(M.log_buf, -1, -1, false, { entry })
    if M.log_win and vim.api.nvim_win_is_valid(M.log_win) then
      local line_count = vim.api.nvim_buf_line_count(M.log_buf)
      vim.api.nvim_win_set_cursor(M.log_win, { line_count, 0 })
    end
  end
end

function M.toggle()
  if M.log_win and vim.api.nvim_win_is_valid(M.log_win) then
    vim.api.nvim_win_close(M.log_win, true)
    M.log_win = nil
    M.enabled = false
    return
  end

  M.enabled = true

  if not M.log_buf or not vim.api.nvim_buf_is_valid(M.log_buf) then
    M.log_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.log_buf, "llama-debug")
    vim.bo[M.log_buf].buftype = "nofile"
    vim.bo[M.log_buf].swapfile = false
    if #M.entries > 0 then
      vim.api.nvim_buf_set_lines(M.log_buf, 0, -1, false, M.entries)
    end
  end

  vim.cmd("vsplit")
  M.log_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.log_win, M.log_buf)
  vim.cmd("wincmd p")
end

function M.clear()
  M.entries = {}
  if M.log_buf and vim.api.nvim_buf_is_valid(M.log_buf) then
    vim.api.nvim_buf_set_lines(M.log_buf, 0, -1, false, {})
  end
end

return M
