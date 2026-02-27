--- Instruction-based editing (gp.nvim-style inline replace)
local debug = require("llama.debug")

local M = {}

M.active_job = nil

--- Build chat messages for instruct (gp.nvim style)
function M.build(selection, filetype, filename, instruction)
  local system_prompt =
    "You are a code editor. When given code and an instruction, output the modified code only. No explanations."

  local user_content = string.format(
    "I have the following from %s:\n\n```%s\n%s\n```\n\n%s\n\nRespond exclusively with the snippet that should replace the selection above.",
    filename,
    filetype,
    selection,
    instruction
  )

  return {
    { role = "system", content = system_prompt },
    { role = "user", content = user_content },
  }
end

--- Strip code fences from completed response, return only content inside first fence block
function M.strip_fences(text)
  local fence_start = text:find("```[^\n]*\n")
  if not fence_start then
    return text
  end
  local content_start = text:find("\n", fence_start) + 1
  local fence_end = text:find("\n```", content_start)
  if not fence_end then
    return text:sub(content_start)
  end
  return text:sub(content_start, fence_end)
end

--- Stop any active instruct job
function M.stop()
  if M.active_job then
    pcall(vim.fn.jobstop, M.active_job)
    M.active_job = nil
  end
end

--- Parse SSE streaming chunks for content deltas
local function parse_sse(lines)
  local content = ""
  for _, line in ipairs(lines) do
    if #line > 6 and line:sub(1, 6) == "data: " then
      line = line:sub(7)
    end
    if line == "" or line:match("^%s*$") or line == "[DONE]" then
      goto continue
    end
    local ok, response = pcall(vim.fn.json_decode, line)
    if ok then
      local choices = response.choices or { {} }
      if choices[1].delta and choices[1].delta.content then
        local delta = choices[1].delta.content
        if type(delta) == "string" then
          content = content .. delta
        end
      end
    end
    ::continue::
  end
  return content
end

--- Undojoin helper (like gp.nvim's helpers.undojoin)
local function undojoin(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.cmd.undojoin)
  end
end

--- Main entry: visual selection -> prompt -> delete -> stream replacement
function M.instruct(l0, l1, config)
  M.stop()

  local bufnr = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_line_count(bufnr)

  l0 = math.max(1, math.min(l0, buf_lines))
  l1 = math.max(l0, math.min(l1, buf_lines))

  debug.log("instruct", string.format("range: %d-%d (buf has %d lines)", l0, l1, buf_lines))

  local lines = vim.api.nvim_buf_get_lines(bufnr, l0 - 1, l1, false)
  local selection = table.concat(lines, "\n")
  local filetype = vim.bo[bufnr].filetype or ""
  local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t") or ""

  -- measure indentation to preserve it
  local min_indent = nil
  local use_tabs = false
  for _, line in ipairs(lines) do
    if not line:match("^%s*$") then
      local indent = line:match("^%s*")
      if indent:match("\t") then
        use_tabs = true
      end
      if min_indent == nil or #indent < min_indent then
        min_indent = #indent
      end
    end
  end
  min_indent = min_indent or 0
  local prefix = string.rep(use_tabs and "\t" or " ", min_indent)

  -- prompt user for instruction
  local instruction = vim.fn.input("Instruction: ")
  if instruction == "" then
    return
  end

  debug.log("instruct", "instruction: " .. instruction)

  local messages = M.build(selection, filetype, filename, instruction)

  local request = {
    messages = messages,
    temperature = 0.3,
    stream = true,
  }
  if config.model_inst and #config.model_inst > 0 then
    request.model = config.model_inst
  end

  local request_json = vim.fn.json_encode(request)

  local curl_args = {
    "curl",
    "--silent",
    "--no-buffer",
    "--request",
    "POST",
    "--url",
    config.endpoint_inst,
    "--header",
    "Content-Type: application/json",
    "--data",
    "@-",
  }
  if config.api_key and #config.api_key > 0 then
    table.insert(curl_args, "--header")
    table.insert(curl_args, "Authorization: Bearer " .. config.api_key)
  end

  -- delete selection and insert one empty line as placeholder
  vim.api.nvim_buf_set_lines(bufnr, l0 - 1, l1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { l0, 0 })

  -- streaming state (gp.nvim-style)
  local accumulated = "" -- full raw response
  local content = "" -- content inside fences (or raw if no fences)
  local first_line = l0 - 1 -- 0-indexed insert point
  local finished_lines = 0 -- lines fully written (won't be touched again)
  local skip_first_undojoin = true
  local inside_fence = false
  local fence_done = false

  --- extract content from accumulated, handling fence detection
  local function extract_content()
    if fence_done then
      return content
    end

    if not inside_fence then
      local fence_start = accumulated:find("```[^\n]*\n")
      if fence_start then
        inside_fence = true
        local after = accumulated:find("\n", fence_start) + 1
        content = accumulated:sub(after)
      else
        -- no fence yet — if we see a full line without fence markers, treat as raw
        if accumulated:find("\n") and not accumulated:match("^%s*```") then
          content = accumulated
        else
          return nil -- wait for more data
        end
      end
    else
      -- inside fence, update content from after the opening fence
      local fence_start = accumulated:find("```[^\n]*\n")
      local after = accumulated:find("\n", fence_start) + 1
      content = accumulated:sub(after)
    end

    -- check for closing fence
    local close = content:find("\n```")
    if close then
      content = content:sub(1, close)
      fence_done = true
    end

    return content
  end

  --- write content to buffer (gp.nvim style: only update unfinished lines)
  local function write_to_buffer()
    local text = extract_content()
    if not text then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if skip_first_undojoin then
      skip_first_undojoin = false
    else
      undojoin(bufnr)
    end

    -- clean previous unfinished lines
    local prev_line_count = #vim.split(content, "\n")
    -- we need to count based on what was written before
    local old_total = math.max(1, finished_lines + 1) -- at least the placeholder
    vim.api.nvim_buf_set_lines(bufnr, first_line + finished_lines, first_line + old_total, false, {})

    undojoin(bufnr)

    -- split content into lines and add prefix
    local result_lines = vim.split(text, "\n", { plain = true })
    for i, line in ipairs(result_lines) do
      if line ~= "" and not line:match("^" .. prefix) then
        result_lines[i] = prefix .. line
      end
    end

    -- insert only unfinished lines (from finished_lines onward)
    local unfinished = {}
    for i = finished_lines + 1, #result_lines do
      table.insert(unfinished, result_lines[i])
    end

    vim.api.nvim_buf_set_lines(bufnr, first_line + finished_lines, first_line + finished_lines, false, unfinished)

    -- all lines except the last are now "finished"
    finished_lines = math.max(0, #result_lines - 1)
  end

  M.active_job = vim.fn.jobstart(curl_args, {
    on_stdout = function(_, data, _)
      local chunk = parse_sse(data)
      if #chunk == 0 then
        return
      end
      accumulated = accumulated .. chunk
      vim.schedule(write_to_buffer)
    end,
    on_exit = function(_, exit_code, _)
      M.active_job = nil
      vim.schedule(function()
        if exit_code ~= 0 then
          vim.notify("llama.lua: instruct failed (exit " .. exit_code .. ")", vim.log.levels.WARN)
          return
        end

        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end

        -- final write to flush any remaining content
        local text = extract_content()
        if not text or #text == 0 then
          text = accumulated
        end

        local result_lines = vim.split(text, "\n", { plain = true })

        -- remove trailing empty lines
        while #result_lines > 0 and result_lines[#result_lines] == "" do
          result_lines[#result_lines] = nil
        end

        -- add prefix
        for i, line in ipairs(result_lines) do
          if line ~= "" and not line:match("^" .. prefix) then
            result_lines[i] = prefix .. line
          end
        end

        -- final replace of everything we've written
        undojoin(bufnr)
        local written_end = first_line + math.max(finished_lines + 1, 1)
        local buf_total = vim.api.nvim_buf_line_count(bufnr)
        written_end = math.min(written_end, buf_total)
        vim.api.nvim_buf_set_lines(bufnr, first_line, written_end, false, result_lines)

        debug.log("instruct", "done")
      end)
    end,
    stdout_buffered = false,
  })

  if M.active_job and M.active_job > 0 then
    vim.fn.chansend(M.active_job, request_json)
    vim.fn.chanclose(M.active_job, "stdin")
    debug.log("instruct", "request sent to " .. config.endpoint_inst)
  else
    vim.notify("llama.lua: failed to start instruct request", vim.log.levels.ERROR)
  end
end

return M
