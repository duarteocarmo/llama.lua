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

--- Strip code fences from response, return only the content inside the first fence block
function M.strip_fences(text)
  -- find first opening fence (with optional language tag)
  local fence_start = text:find("```[^\n]*\n")
  if not fence_start then
    -- no fences, return as-is
    return text
  end

  -- skip past the opening fence line
  local content_start = text:find("\n", fence_start) + 1

  -- find closing fence
  local fence_end = text:find("\n```", content_start)
  if not fence_end then
    -- no closing fence, return everything after opening
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

  -- delete selection and place cursor at start
  vim.api.nvim_buf_set_lines(bufnr, l0 - 1, l1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { l0, 0 })

  local accumulated = ""
  local current_line = l0 - 1 -- 0-indexed, the empty line we inserted
  local first_token = true
  local inside_fence = false
  local fence_done = false

  M.active_job = vim.fn.jobstart(curl_args, {
    on_stdout = function(_, data, _)
      local content = parse_sse(data)
      if #content == 0 then
        return
      end
      accumulated = accumulated .. content

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end

        -- process accumulated content for fence stripping
        local to_write = ""
        if fence_done then
          -- already got closing fence, ignore everything
          return
        end

        -- check if we've entered a fence
        if not inside_fence then
          local fence_start = accumulated:find("```[^\n]*\n")
          if fence_start then
            inside_fence = true
            local after = accumulated:find("\n", fence_start) + 1
            to_write = accumulated:sub(after)
            -- check if closing fence is already in this chunk
            local close = to_write:find("\n```")
            if close then
              to_write = to_write:sub(1, close)
              fence_done = true
            end
          else
            -- no fence yet, might be raw code — wait for more or use as-is
            -- if we see a newline and no fence pattern, treat as raw
            if accumulated:find("\n") and not accumulated:match("^%s*```") then
              to_write = accumulated
            else
              return
            end
          end
        else
          to_write = accumulated
          local close = to_write:find("\n```")
          if close then
            to_write = to_write:sub(1, close)
            fence_done = true
          end
        end

        -- split into lines and write
        local result_lines = vim.split(to_write, "\n", { plain = true })

        -- add indentation prefix to each line
        for i, line in ipairs(result_lines) do
          if line ~= "" then
            -- only add prefix if the line doesn't already have sufficient indent
            if not line:match("^" .. prefix) then
              result_lines[i] = prefix .. line
            end
          end
        end

        -- replace from our start position
        local end_line = math.min(current_line + 1, vim.api.nvim_buf_line_count(bufnr))
        vim.api.nvim_buf_set_lines(bufnr, current_line, end_line, false, result_lines)

        -- track where we are now
        current_line = current_line + #result_lines - 1

        if first_token then
          first_token = false
          debug.log("instruct", "first token received")
        end
      end)
    end,
    on_exit = function(_, exit_code, _)
      M.active_job = nil
      vim.schedule(function()
        if exit_code ~= 0 then
          vim.notify("llama.lua: instruct failed (exit " .. exit_code .. ")", vim.log.levels.WARN)
          return
        end

        -- if we never entered a fence, the accumulated content is raw
        if not inside_fence and #accumulated > 0 and not fence_done then
          if vim.api.nvim_buf_is_valid(bufnr) then
            local result_lines = vim.split(accumulated, "\n", { plain = true })
            for i, line in ipairs(result_lines) do
              if line ~= "" and not line:match("^" .. prefix) then
                result_lines[i] = prefix .. line
              end
            end
            local end_line = math.min(current_line + 1, vim.api.nvim_buf_line_count(bufnr))
            vim.api.nvim_buf_set_lines(bufnr, current_line, end_line, false, result_lines)
          end
        end

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
