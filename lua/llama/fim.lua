local cache = require("llama.cache")
local ring = require("llama.ring")
local util = require("llama.util")
local debug = require("llama.debug")

local M = {}

M.hint_shown = false
M.data = {}
M.current_job = nil
M.timer_fim = nil
M.indent_last = -1
M.pos_y_pick = -9999

M._generation = 0

local ns_fim = vim.api.nvim_create_namespace("llama_fim")
local EXTMARK_HINT = 1
local EXTMARK_LINES = 2

function M.ctx_local(pos_x, pos_y, prev, config)
  local max_y = vim.fn.line("$")

  local line_cur, line_cur_prefix, line_cur_suffix
  local lines_prefix, lines_suffix
  local indent

  if #prev == 0 then
    line_cur = vim.fn.getline(pos_y)
    line_cur_prefix = line_cur:sub(1, pos_x)
    line_cur_suffix = line_cur:sub(pos_x + 1)

    lines_prefix = vim.fn.getline(math.max(1, pos_y - config.n_prefix), pos_y - 1)
    lines_suffix = vim.fn.getline(pos_y + 1, math.min(max_y, pos_y + config.n_suffix))

    if line_cur:match("^%s*$") then
      indent = 0
      line_cur_prefix = ""
      line_cur_suffix = ""
    else
      indent = #(line_cur:match("^(%s*)") or "")
    end
  else
    if #prev == 1 then
      line_cur = vim.fn.getline(pos_y) .. prev[1]
    else
      line_cur = prev[#prev]
    end

    line_cur_prefix = line_cur
    line_cur_suffix = ""

    lines_prefix = vim.fn.getline(math.max(1, pos_y - config.n_prefix + #prev - 1), pos_y - 1)
    if #prev > 1 then
      table.insert(lines_prefix, vim.fn.getline(pos_y) .. prev[1])
      for i = 2, #prev - 1 do
        table.insert(lines_prefix, prev[i])
      end
    end

    lines_suffix = vim.fn.getline(pos_y + 1, math.min(max_y, pos_y + config.n_suffix))
    indent = M.indent_last
  end

  local prefix = table.concat(lines_prefix, "\n") .. "\n"
  local middle = line_cur_prefix
  local suffix = line_cur_suffix .. "\n" .. table.concat(lines_suffix, "\n") .. "\n"

  return {
    prefix = prefix,
    middle = middle,
    suffix = suffix,
    indent = indent,
    line_cur = line_cur,
    line_cur_prefix = line_cur_prefix,
    line_cur_suffix = line_cur_suffix,
  }
end

function M.render(pos_x, pos_y, raw, config)
  -- don't show during popup menu
  if vim.fn.pumvisible() == 1 then
    return
  end

  local ok, response = pcall(vim.fn.json_decode, raw)
  if not ok then
    return
  end

  local can_accept = true
  local content = {}

  local raw_content = response.content or ""
  for part in vim.gsplit(raw_content, "\n", { plain = true }) do
    content[#content + 1] = part
  end

  -- remove trailing empty lines
  while #content > 0 and content[#content] == "" do
    content[#content] = nil
  end

  -- timing info
  local n_cached = response.tokens_cached or 0
  local truncated = response["timings/truncated"] or false
  local n_prompt = response["timings/prompt_n"] or 0
  local t_prompt_ms = tonumber(response["timings/prompt_ms"] or "1.0") or 1.0
  local s_prompt = tonumber(response["timings/prompt_per_second"] or "0.0") or 0.0
  local n_predict = response["timings/predicted_n"] or 0
  local t_predict_ms = tonumber(response["timings/predicted_ms"] or "1.0") or 1.0
  local s_predict = tonumber(response["timings/predicted_per_second"] or "0.0") or 0.0
  local has_info = true

  if #content == 0 then
    content = { "" }
    can_accept = false
  end

  local line_cur = vim.fn.getline(pos_y)

  -- if line is all whitespace, trim leading spaces from suggestion
  if line_cur:match("^%s*$") then
    local lead_suggestion = #(content[1]:match("^(%s*)") or "")
    local lead = math.min(lead_suggestion, #line_cur)
    line_cur = content[1]:sub(1, lead)
    content[1] = content[1]:sub(lead + 1)
  end

  local line_cur_prefix = line_cur:sub(1, pos_x)
  local line_cur_suffix = line_cur:sub(pos_x + 1)

  if #content == 1 and content[1] == "" then
    content = { "" }
  end

  if #content > 1 and content[1] == "" then
    local next_lines = vim.fn.getline(pos_y + 1, pos_y + #content - 1)
    local match = true
    for i = 2, #content do
      if content[i] ~= (next_lines[i - 1] or "") then
        match = false
        break
      end
    end
    if match then
      content = { "" }
    end
  end

  if #content == 1 and content[1] == line_cur_suffix then
    content = { "" }
  end

  -- find first non-empty line below
  local cmp_y = pos_y + 1
  local max_line = vim.fn.line("$")
  while cmp_y <= max_line and (vim.fn.getline(cmp_y) or ""):match("^%s*$") do
    cmp_y = cmp_y + 1
  end

  local cmp_line = vim.fn.getline(cmp_y) or ""
  if (line_cur_prefix .. content[1]) == cmp_line then
    if #content == 1 then
      content = { "" }
    elseif #content == 2 then
      local next_line = vim.fn.getline(cmp_y + 1) or ""
      if content[#content] == next_line:sub(1, #content[#content]) then
        content = { "" }
      end
    elseif #content > 2 then
      local mid = vim.list_slice(content, 2, #content)
      local cmp_lines = vim.fn.getline(cmp_y + 1, cmp_y + #content - 1)
      if table.concat(mid, "\n") == table.concat(cmp_lines, "\n") then
        content = { "" }
      end
    end
  end

  -- append suffix to last line
  content[#content] = content[#content] .. line_cur_suffix

  -- if only whitespace, don't accept
  if table.concat(content, "\n"):match("^%s*$") then
    can_accept = false
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- build info string
  local info = ""
  if config.show_info > 0 and has_info then
    local prefix_str = "   "
    if truncated then
      info = string.format(
        "%s | WARNING: context full: %d, increase server context or reduce ring_n_chunks",
        config.show_info == 2 and prefix_str or "llama.lua",
        n_cached
      )
    else
      info = string.format(
        "%s | c: %d, r: %d/%d, e: %d, q: %d/16, C: %d/%d | p: %d (%.2f ms, %.2f t/s) | g: %d (%.2f ms, %.2f t/s)",
        config.show_info == 2 and prefix_str or "llama.lua",
        n_cached,
        #ring.chunks,
        config.ring_n_chunks,
        ring.n_evict,
        #ring.queued,
        #vim.tbl_keys(cache.data),
        config.max_cache_keys,
        n_prompt,
        t_prompt_ms,
        s_prompt,
        n_predict,
        t_predict_ms,
        s_predict
      )
    end

    if config.show_info == 1 then
      vim.o.statusline = info
      info = ""
    end
  end

  -- render virtual text
  local virt_text = { { content[1], "llama_hl_fim_hint" } }
  if info ~= "" then
    virt_text[#virt_text + 1] = { info, "llama_hl_fim_info" }
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns_fim, pos_y - 1, pos_x, {
    id = EXTMARK_HINT,
    virt_text = virt_text,
    virt_text_pos = (content[1] == "" and #content == 1) and "eol" or "overlay",
  })

  if #content > 1 then
    local virt_lines = {}
    for i = 2, #content do
      virt_lines[#virt_lines + 1] = { { content[i], "llama_hl_fim_hint" } }
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns_fim, pos_y - 1, 0, {
      id = EXTMARK_LINES,
      virt_lines = virt_lines,
    })
  end

  -- set accept keymaps
  if config.keymap_fim_accept_full ~= "" then
    vim.keymap.set("i", config.keymap_fim_accept_full, function()
      M.accept("full", config)
    end, { buffer = true, silent = true })
  end
  if config.keymap_fim_accept_line ~= "" then
    vim.keymap.set("i", config.keymap_fim_accept_line, function()
      M.accept("line", config)
    end, { buffer = true, silent = true })
  end
  if config.keymap_fim_accept_word ~= "" then
    vim.keymap.set("i", config.keymap_fim_accept_word, function()
      M.accept("word", config)
    end, { buffer = true, silent = true })
  end

  M.hint_shown = true
  M.data = {
    pos_x = pos_x,
    pos_y = pos_y,
    line_cur = line_cur,
    can_accept = can_accept,
    content = content,
  }
end

function M.hide(config)
  local t0 = vim.loop.hrtime()
  local was_shown = M.hint_shown
  M.hint_shown = false
  M._generation = M._generation + 1

  local bufnr = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_fim, EXTMARK_HINT)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_fim, EXTMARK_LINES)
  local t_extmarks = (vim.loop.hrtime() - t0) / 1e6

  if config and config.show_info == 1 then
    vim.o.statusline = ""
  end

  local t1 = vim.loop.hrtime()
  if config then
    if config.keymap_fim_accept_full ~= "" then
      pcall(vim.keymap.del, "i", config.keymap_fim_accept_full, { buffer = true })
    end
    if config.keymap_fim_accept_line ~= "" then
      pcall(vim.keymap.del, "i", config.keymap_fim_accept_line, { buffer = true })
    end
    if config.keymap_fim_accept_word ~= "" then
      pcall(vim.keymap.del, "i", config.keymap_fim_accept_word, { buffer = true })
    end
  end
  local t_keymaps = (vim.loop.hrtime() - t1) / 1e6

  debug.log(
    "fim_hide",
    string.format("was_shown=%s extmarks=%.2fms keymaps=%.2fms", tostring(was_shown), t_extmarks, t_keymaps)
  )
end

function M.try_hint(pos_x, pos_y, config)
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("^i") then
    return
  end

  local ctx = M.ctx_local(pos_x, pos_y, {}, config)
  local hash = util.sha256(ctx.prefix .. ctx.middle .. "Î" .. ctx.suffix)

  local raw = cache.get(hash)

  if raw ~= nil then
    M.render(pos_x, pos_y, raw, config)
    if M.hint_shown then
      M.request(pos_x, pos_y, true, M.data.content, true, config)
    end
    return
  end

  local pm = ctx.prefix .. ctx.middle
  local suffix = ctx.suffix
  local gen = M._generation
  local best_raw = nil
  local best_len = 0
  local BATCH = 16

  local function scan_batch(start_i)
    -- abort if a new keystroke arrived
    if M._generation ~= gen then
      return
    end

    local end_i = math.min(start_i + BATCH - 1, 127)
    for i = start_i, end_i do
      local removed = pm:sub(-(1 + i))
      local ctx_new = pm:sub(1, -(2 + i)) .. "Î" .. suffix
      local hash_new = util.sha256(ctx_new)
      local response_cached = cache.get(hash_new)

      if response_cached ~= nil and response_cached ~= "" then
        local ok, resp = pcall(vim.fn.json_decode, response_cached)
        if ok and resp.content then
          if resp.content:sub(1, i + 1) == removed then
            resp.content = resp.content:sub(i + 2)
            if #resp.content > 0 then
              if best_raw == nil or #resp.content > best_len then
                best_len = #resp.content
                best_raw = vim.fn.json_encode(resp)
              end
            end
          end
        end
      end
    end

    if end_i >= 127 or M._generation ~= gen then
      -- done scanning — render if we found something and generation is still current
      if best_raw ~= nil and M._generation == gen then
        M.render(pos_x, pos_y, best_raw, config)
        if M.hint_shown then
          M.request(pos_x, pos_y, true, M.data.content, true, config)
        end
      end
    else
      -- yield back to event loop, then continue
      vim.schedule(function()
        scan_batch(end_i + 1)
      end)
    end
  end

  scan_batch(0)
end

function M.accept(accept_type, config)
  if not M.data or not M.data.can_accept or not M.data.content or #M.data.content == 0 then
    M.hide(config)
    return
  end

  local pos_x = M.data.pos_x
  local pos_y = M.data.pos_y
  local line_cur = M.data.line_cur
  local content = M.data.content

  if accept_type ~= "word" then
    -- insert first line
    vim.fn.setline(pos_y, line_cur:sub(1, pos_x) .. content[1])
  else
    local suffix = line_cur:sub(pos_x + 1)
    local text_to_match = content[1]:sub(1, #content[1] - #suffix)
    local word = text_to_match:match("^%s*%S+") or ""
    vim.fn.setline(pos_y, line_cur:sub(1, pos_x) .. word .. suffix)
  end

  -- insert remaining lines
  if #content > 1 and accept_type == "full" then
    vim.fn.append(pos_y, vim.list_slice(content, 2))
  end

  -- move cursor
  if accept_type == "word" then
    local suffix = line_cur:sub(pos_x + 1)
    local text_to_match = content[1]:sub(1, #content[1] - #suffix)
    local word = text_to_match:match("^%s*%S+") or ""
    vim.fn.cursor(pos_y, pos_x + #word + 1)
  elseif accept_type == "line" or #content == 1 then
    vim.fn.cursor(pos_y, pos_x + #content[1] + 1)
    if #content > 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  else
    vim.fn.cursor(pos_y + #content - 1, #content[#content] + 1)
  end

  M.hide(config)
end

function M.inline(is_auto, use_cache, config)
  if M.hint_shown and not is_auto then
    M.hide(config)
    return ""
  end
  M.request(-1, -1, is_auto, {}, use_cache, config)
  return ""
end

function M.request(pos_x, pos_y, is_auto, prev, use_cache, config)
  if pos_x < 0 then
    pos_x = vim.fn.col(".") - 1
  end
  if pos_y < 0 then
    pos_y = vim.fn.line(".")
  end

  -- debounce: if a request is in flight, schedule a retry
  if M.current_job ~= nil then
    if M.timer_fim then
      vim.fn.timer_stop(M.timer_fim)
      M.timer_fim = nil
    end
    M.timer_fim = vim.fn.timer_start(100, function()
      M.timer_fim = nil
      M.request(pos_x, pos_y, true, prev, use_cache, config)
    end)
    return
  end

  local ctx = M.ctx_local(pos_x, pos_y, prev, config)

  if is_auto and #ctx.line_cur_suffix > config.max_line_suffix then
    return
  end

  local t_max_predict_ms = config.t_max_predict_ms
  if #prev == 0 then
    t_max_predict_ms = 250
  end

  -- compute hashes
  local hashes = {}
  hashes[#hashes + 1] = util.sha256(ctx.prefix .. ctx.middle .. "Î" .. ctx.suffix)

  local prefix_trim = ctx.prefix
  for _ = 1, 3 do
    prefix_trim = prefix_trim:gsub("^[^\n]*\n", "", 1)
    if prefix_trim == "" then
      break
    end
    hashes[#hashes + 1] = util.sha256(prefix_trim .. ctx.middle .. "Î" .. ctx.suffix)
  end

  -- check cache
  if use_cache then
    for _, h in ipairs(hashes) do
      if cache.get(h) ~= nil then
        return
      end
    end
  end

  M.indent_last = ctx.indent

  -- evict similar chunks from ring
  local cur_line = vim.fn.line(".")
  local max_y = vim.fn.line("$")
  local text = vim.fn.getline(
    math.max(1, cur_line - math.floor(config.ring_chunk_size / 2)),
    math.min(max_y, cur_line + math.floor(config.ring_chunk_size / 2))
  )
  local l0 = util.rand(1, math.max(1, #text - math.floor(config.ring_chunk_size / 2)))
  local l1 = math.min(l0 + math.floor(config.ring_chunk_size / 2), #text)
  local chunk = vim.list_slice(text, l0, l1)

  for i = #ring.chunks, 1, -1 do
    if util.chunk_sim(ring.chunks[i].data, chunk) > 0.5 then
      table.remove(ring.chunks, i)
      ring.n_evict = ring.n_evict + 1
    end
  end

  local extra = ring.get_extra()

  local request = {
    id_slot = 0,
    input_prefix = ctx.prefix,
    input_suffix = ctx.suffix,
    input_extra = extra,
    prompt = ctx.middle,
    n_predict = config.n_predict,
    stop = config.stop_strings,
    n_indent = ctx.indent,
    top_k = 40,
    top_p = 0.90,
    samplers = { "top_k", "top_p", "infill" },
    stream = false,
    cache_prompt = true,
    t_max_prompt_ms = config.t_max_prompt_ms,
    t_max_predict_ms = t_max_predict_ms,
    response_fields = {
      "content",
      "timings/prompt_n",
      "timings/prompt_ms",
      "timings/prompt_per_token_ms",
      "timings/prompt_per_second",
      "timings/predicted_n",
      "timings/predicted_ms",
      "timings/predicted_per_token_ms",
      "timings/predicted_per_second",
      "truncated",
      "tokens_cached",
    },
  }

  if config.model_fim and #config.model_fim > 0 then
    request.model = config.model_fim
  end

  local curl_args = {
    "curl",
    "--silent",
    "--no-buffer",
    "--request",
    "POST",
    "--url",
    config.endpoint_fim,
    "--header",
    "Content-Type: application/json",
    "--data",
    "@-",
  }

  if config.api_key and #config.api_key > 0 then
    table.insert(curl_args, "--header")
    table.insert(curl_args, "Authorization: Bearer " .. config.api_key)
  end

  local request_json = vim.fn.json_encode(request)

  M.current_job = vim.fn.jobstart(curl_args, {
    on_stdout = function(_, data, _)
      local raw = table.concat(data, "\n")
      if #raw == 0 then
        return
      end

      -- validate JSON
      if not raw:match("^%s*{") or not raw:match('"content"%s*:') then
        return
      end

      local ok, _ = pcall(vim.fn.json_decode, raw)
      if not ok then
        return
      end

      -- cache the response
      for _, h in ipairs(hashes) do
        cache.insert(h, raw, config.max_cache_keys)
      end

      -- show hint if nothing displayed
      if not M.hint_shown or not (M.data and M.data.can_accept) then
        debug.log("fim_on_response", (vim.fn.json_decode(raw) or {}).content or "")

        vim.schedule(function()
          local cx = vim.fn.col(".") - 1
          local cy = vim.fn.line(".")
          M.try_hint(cx, cy, config)
        end)
      end
    end,
    on_exit = function(_, exit_code, _)
      if exit_code ~= 0 then
        vim.schedule(function()
          vim.notify("llama.lua: FIM job failed with exit code " .. exit_code, vim.log.levels.WARN)
        end)
      end
      M.current_job = nil
    end,
    stdout_buffered = true,
  })

  if M.current_job and M.current_job > 0 then
    vim.fn.chansend(M.current_job, request_json)
    vim.fn.chanclose(M.current_job, "stdin")
  end

  local delta_y = math.abs(pos_y - M.pos_y_pick)
  if is_auto and delta_y > 32 then
    ring.pick_chunk(
      vim.fn.getline(math.max(1, pos_y - config.ring_scope), math.max(1, pos_y - config.n_prefix)),
      false,
      false,
      config
    )
    ring.pick_chunk(
      vim.fn.getline(
        math.min(max_y, pos_y + config.n_suffix),
        math.min(max_y, pos_y + config.n_suffix + config.ring_chunk_size)
      ),
      false,
      false,
      config
    )
    M.pos_y_pick = pos_y
  end
end

return M
