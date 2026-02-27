local fim = require("llama.fim")
local ring = require("llama.ring")
local debug = require("llama.debug")
local server = require("llama.server")
local inst = require("llama.inst")

local M = {}

M.enabled = false
M.t_last_move = vim.loop.hrtime()
M.ring_timer = nil
M.debounce_timer = nil

local default_config = {
  endpoint_fim = "http://127.0.0.1:8012/infill",
  endpoint_inst = "http://127.0.0.1:8012/v1/chat/completions",
  model_fim = "",
  model_inst = "",
  api_key = "",
  n_prefix = 256,
  n_suffix = 64,
  n_predict = 128,
  stop_strings = {},
  t_max_prompt_ms = 500,
  t_max_predict_ms = 1000,
  show_info = 2,
  auto_fim = true,
  max_line_suffix = 8,
  max_cache_keys = 250,
  ring_n_chunks = 16,
  ring_chunk_size = 64,
  ring_scope = 1024,
  ring_update_ms = 1000,
  auto_fim_debounce_ms = 300,
  server_managed = false,
  server_args = { "--fim-qwen-7b-default" },
  filetypes = {
    ["*"] = true,
    ["yaml"] = false,
    ["markdown"] = false,
    ["help"] = false,
    ["gitcommit"] = false,
    ["gitrebase"] = false,
    ["hgcommit"] = false,
  },
  keymap_fim_trigger = "<leader>llf",
  keymap_fim_accept_full = "<Tab>",
  keymap_fim_accept_line = "<S-Tab>",
  keymap_fim_accept_word = "<leader>ll]",
  keymap_inst_trigger = "<leader>lli",
  keymap_debug_toggle = "<leader>lld",
  enable_at_startup = true,
}

M.config = vim.deepcopy(default_config)

local augroup = vim.api.nvim_create_augroup("llama", { clear = true })

local function buf_allowed()
  local ft = vim.bo.filetype
  local ft_config = M.config.filetypes

  local val = ft_config[ft]
  if val ~= nil then
    if type(val) == "function" then
      return val()
    end
    return val
  end

  val = ft_config["*"]
  if val ~= nil then
    if type(val) == "function" then
      return val()
    end
    return val
  end

  return true
end

local function on_move()
  M.t_last_move = vim.loop.hrtime()
  fim.hide(M.config)

  if not buf_allowed() then
    return
  end

  vim.schedule(function()
    local pos_x = vim.fn.col(".") - 1
    local pos_y = vim.fn.line(".")
    fim.try_hint(pos_x, pos_y, M.config)
  end)
end

local function on_cursor_moved_i()
  M.t_last_move = vim.loop.hrtime()
  fim.hide(M.config)

  if not buf_allowed() then
    return
  end

  if M.debounce_timer then
    vim.fn.timer_stop(M.debounce_timer)
    M.debounce_timer = nil
  end

  M.debounce_timer = vim.fn.timer_start(M.config.auto_fim_debounce_ms, function()
    M.debounce_timer = nil
    vim.schedule(function()
      local pos_x = vim.fn.col(".") - 1
      local pos_y = vim.fn.line(".")
      fim.try_hint(pos_x, pos_y, M.config)
      fim.request(-1, -1, true, {}, true, M.config)
    end)
  end)
end

local function setup_autocmds()
  vim.api.nvim_clear_autocmds({ group = augroup })

  vim.api.nvim_create_autocmd("InsertLeavePre", {
    group = augroup,
    pattern = "*",
    callback = function()
      fim.hide(M.config)
    end,
  })

  vim.api.nvim_create_autocmd("CompleteChanged", {
    group = augroup,
    pattern = "*",
    callback = function()
      fim.hide(M.config)
    end,
  })

  vim.api.nvim_create_autocmd("CompleteDone", {
    group = augroup,
    pattern = "*",
    callback = on_move,
  })

  if M.config.auto_fim then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = augroup,
      pattern = "*",
      callback = on_move,
    })

    vim.api.nvim_create_autocmd("CursorMovedI", {
      group = augroup,
      pattern = "*",
      callback = on_cursor_moved_i,
    })
  end

  vim.api.nvim_create_autocmd("TextYankPost", {
    group = augroup,
    pattern = "*",
    callback = function()
      if vim.v.event.operator == "y" then
        ring.pick_chunk(vim.v.event.regcontents, false, true, M.config)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*",
    callback = function()
      vim.defer_fn(function()
        local cur = vim.fn.line(".")
        local half = math.floor(M.config.ring_chunk_size / 2)
        local lines = vim.fn.getline(math.max(1, cur - half), math.min(vim.fn.line("$"), cur + half))
        ring.pick_chunk(lines, true, true, M.config)
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    pattern = "*",
    callback = function()
      local cur = vim.fn.line(".")
      local half = math.floor(M.config.ring_chunk_size / 2)
      local lines = vim.fn.getline(math.max(1, cur - half), math.min(vim.fn.line("$"), cur + half))
      ring.pick_chunk(lines, true, true, M.config)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    pattern = "*",
    callback = function()
      local cur = vim.fn.line(".")
      local half = math.floor(M.config.ring_chunk_size / 2)
      local lines = vim.fn.getline(math.max(1, cur - half), math.min(vim.fn.line("$"), cur + half))
      ring.pick_chunk(lines, true, true, M.config)
    end,
  })
end

function M.enable()
  if M.enabled then
    return
  end

  if M.config.keymap_fim_trigger ~= "" then
    vim.keymap.set("i", M.config.keymap_fim_trigger, function()
      if not buf_allowed() then
        return ""
      end
      return fim.inline(false, false, M.config)
    end, { expr = true, silent = true })
  end

  if M.config.keymap_debug_toggle ~= "" then
    vim.keymap.set("n", M.config.keymap_debug_toggle, function()
      debug.toggle()
    end, { silent = true })
  end

  if M.config.keymap_inst_trigger ~= "" then
    vim.keymap.set("v", M.config.keymap_inst_trigger, ":LlamaInstruct<CR>", { silent = true })
  end

  setup_autocmds()
  fim.hide(M.config)

  if M.config.ring_n_chunks > 0 then
    local function ring_tick()
      ring.update(M.config, M.t_last_move)
    end

    M.ring_timer = vim.fn.timer_start(M.config.ring_update_ms, function()
      ring_tick()
    end, { ["repeat"] = -1 })
  end

  M.enabled = true
  debug.log("plugin enabled")
end

function M.disable()
  fim.hide(M.config)
  vim.api.nvim_clear_autocmds({ group = augroup })

  if M.ring_timer then
    vim.fn.timer_stop(M.ring_timer)
    M.ring_timer = nil
  end

  if M.debounce_timer then
    vim.fn.timer_stop(M.debounce_timer)
    M.debounce_timer = nil
  end

  if M.config.keymap_fim_trigger ~= "" then
    pcall(vim.keymap.del, "i", M.config.keymap_fim_trigger)
  end
  if M.config.keymap_debug_toggle ~= "" then
    pcall(vim.keymap.del, "n", M.config.keymap_debug_toggle)
  end
  if M.config.keymap_inst_trigger ~= "" then
    pcall(vim.keymap.del, "v", M.config.keymap_inst_trigger)
  end
  inst.stop()

  M.enabled = false
  debug.log("plugin disabled")
end

function M.toggle()
  if M.enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.toggle_auto_fim()
  if not M.enabled then
    return
  end
  M.config.auto_fim = not M.config.auto_fim
  setup_autocmds()
end

function M.is_fim_hint_shown()
  return fim.hint_shown
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})

  vim.api.nvim_set_hl(0, "llama_hl_fim_hint", { fg = "#ff772f", default = true })
  vim.api.nvim_set_hl(0, "llama_hl_fim_info", { fg = "#77ff2f", default = true })

  if vim.fn.executable("curl") ~= 1 then
    vim.notify('llama.lua requires "curl" to be available', vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_create_user_command("LlamaEnable", function()
    M.enable()
  end, {})
  vim.api.nvim_create_user_command("LlamaDisable", function()
    M.disable()
  end, {})
  vim.api.nvim_create_user_command("LlamaToggle", function()
    M.toggle()
  end, {})
  vim.api.nvim_create_user_command("LlamaToggleAutoFim", function()
    M.toggle_auto_fim()
  end, {})
  vim.api.nvim_create_user_command("LlamaInstruct", function(cmd_opts)
    inst.instruct(cmd_opts.line1, cmd_opts.line2, M.config)
  end, { range = true })
  vim.api.nvim_create_user_command("LlamaServerStart", function()
    server.start(M.config)
  end, {})
  vim.api.nvim_create_user_command("LlamaServerStop", function()
    server.stop()
  end, {})

  server.setup(M.config)

  if M.config.enable_at_startup then
    M.enable()
  end
end

return M
