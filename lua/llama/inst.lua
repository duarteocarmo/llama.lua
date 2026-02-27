local debug = require("llama.debug")

local M = {}

M.active_job = nil

function M.build(selection, filetype, filename, instruction)
  local system =
    "You are a code editor. When given code and an instruction, output the modified code only. No explanations."

  local user = string.format(
    "I have the following from %s:\n\n```%s\n%s\n```\n\n%s\n\nRespond exclusively with the snippet that should replace the selection above.",
    filename,
    filetype,
    selection,
    instruction
  )

  return {
    { role = "system", content = system },
    { role = "user", content = user },
  }
end

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

function M.stop()
  if M.active_job then
    pcall(vim.fn.jobstop, M.active_job)
    M.active_job = nil
  end
end

local function parse_sse(lines)
  local content = ""
  for _, line in ipairs(lines) do
    if #line > 6 and line:sub(1, 6) == "data: " then
      line = line:sub(7)
    end
    if line ~= "" and not line:match("^%s*$") and line ~= "[DONE]" then
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
    end
  end
  return content
end

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

  -- measure min indentation
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

  local instruction = vim.fn.input("Instruction: ")
  if instruction == "" then
    return
  end

  debug.log("instruct", "instruction: " .. instruction)

  local request = {
    messages = M.build(selection, filetype, filename, instruction),
    temperature = 0.00,
    stream = true,
  }
  if config.model_inst and #config.model_inst > 0 then
    request.model = config.model_inst
  end

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

  -- delete selection, insert placeholder
  vim.api.nvim_buf_set_lines(bufnr, l0 - 1, l1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { l0, 0 })

  -- streaming state
  local accumulated = ""
  local content = ""
  local first_line = l0 - 1
  local finished_lines = 0
  local prev_written_lines = 1
  local skip_first_undojoin = true
  local inside_fence = false
  local fence_done = false

  local function extract_content()
    if fence_done then
      debug.log("inst_extract", "fence_done (" .. #content .. " chars)")
      return content
    end

    if not inside_fence then
      local fence_start = accumulated:find("```[^\n]*\n")
      if fence_start then
        inside_fence = true
        local after = accumulated:find("\n", fence_start) + 1
        content = accumulated:sub(after)
        debug.log("inst_extract", "fence opened at " .. fence_start)
      else
        if accumulated:find("\n") and not accumulated:match("^%s*```") then
          content = accumulated
          debug.log("inst_extract", "no fence, raw mode")
        else
          debug.log("inst_extract", "waiting for fence")
          return nil
        end
      end
    else
      local fence_start = accumulated:find("```[^\n]*\n")
      local after = accumulated:find("\n", fence_start) + 1
      content = accumulated:sub(after)
      debug.log("inst_extract", "inside fence (" .. #content .. " chars)")
    end

    local close = content:find("\n```")
    if close then
      content = content:sub(1, close)
      fence_done = true
      debug.log("inst_extract", "fence closed (" .. #content .. " chars)")
    end

    return content
  end

  local function write_to_buffer()
    local text = extract_content()
    if not text then
      return
    end

    local result_lines = vim.split(text, "\n", { plain = true })
    for i, line in ipairs(result_lines) do
      if line ~= "" and not line:match("^" .. prefix) then
        result_lines[i] = prefix .. line
      end
    end

    debug.log(
      "inst_write",
      string.format("finished=%d prev=%d total=%d", finished_lines, prev_written_lines, #result_lines)
    )

    if skip_first_undojoin then
      skip_first_undojoin = false
    else
      pcall(vim.cmd.undojoin)
    end

    vim.api.nvim_buf_set_lines(bufnr, first_line + finished_lines, first_line + prev_written_lines, false, {})
    pcall(vim.cmd.undojoin)

    local unfinished = {}
    for i = finished_lines + 1, #result_lines do
      table.insert(unfinished, result_lines[i])
    end
    vim.api.nvim_buf_set_lines(bufnr, first_line + finished_lines, first_line + finished_lines, false, unfinished)

    prev_written_lines = #result_lines
    finished_lines = math.max(0, #result_lines - 1)
  end

  M.active_job = vim.fn.jobstart(curl_args, {
    on_stdout = function(_, data, _)
      local chunk = parse_sse(data)
      if #chunk == 0 then
        return
      end
      debug.log("inst_chunk", vim.inspect(chunk):sub(1, 120))
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

        local text = extract_content()
        if not text or #text == 0 then
          text = accumulated
        end

        local result_lines = vim.split(text, "\n", { plain = true })
        while #result_lines > 0 and result_lines[#result_lines] == "" do
          result_lines[#result_lines] = nil
        end
        for i, line in ipairs(result_lines) do
          if line ~= "" and not line:match("^" .. prefix) then
            result_lines[i] = prefix .. line
          end
        end

        pcall(vim.cmd.undojoin)
        local written_end = first_line + math.max(prev_written_lines, 1)
        written_end = math.min(written_end, vim.api.nvim_buf_line_count(bufnr))
        vim.api.nvim_buf_set_lines(bufnr, first_line, written_end, false, result_lines)

        debug.log("instruct", "done")
      end)
    end,
    stdout_buffered = false,
  })

  if M.active_job and M.active_job > 0 then
    vim.fn.chansend(M.active_job, vim.fn.json_encode(request))
    vim.fn.chanclose(M.active_job, "stdin")
    debug.log("instruct", "sent to " .. config.endpoint_inst)
  end
end

return M
