--- Instruction-based editing
local ring = require("llama.ring")
local debug = require("llama.debug")

local M = {}

M.reqs = {}
M.req_id = 0

local ns_inst = vim.api.nvim_create_namespace("llama_inst")

--- Build the chat messages for an instruct request
function M.build(l0, l1, inst, inst_prev, config)
  local prefix = vim.fn.getline(math.max(1, l0 - config.n_prefix), l0 - 1)
  local selection = vim.fn.getline(l0, l1)
  local suffix = vim.fn.getline(l1 + 1, math.min(vim.fn.line("$"), l1 + config.n_suffix))

  local messages
  if inst_prev and #inst_prev > 0 then
    messages = vim.deepcopy(inst_prev)
  else
    local extra = ring.get_extra()
    local extra_text = ""
    for _, chunk in ipairs(extra) do
      extra_text = extra_text .. (chunk.text or "") .. "\n"
    end

    local system_prompt =
      "You are a text-editing assistant. Respond ONLY with the result of applying INSTRUCTION to SELECTION given the CONTEXT. Maintain the existing text indentation. Do not add extra code blocks. Respond only with the modified block. If the INSTRUCTION is a question, answer it directly. Do not output any extra separators. Consider the local context before (PREFIX) and after (SUFFIX) the SELECTION.\n"
    system_prompt = system_prompt .. "\n"
    system_prompt = system_prompt .. "--- CONTEXT     " .. string.rep("-", 40) .. "\n"
    system_prompt = system_prompt .. extra_text .. "\n"
    system_prompt = system_prompt .. "--- PREFIX      " .. string.rep("-", 40) .. "\n"
    system_prompt = system_prompt .. table.concat(prefix, "\n") .. "\n"
    system_prompt = system_prompt .. "--- SELECTION   " .. string.rep("-", 40) .. "\n"
    system_prompt = system_prompt .. table.concat(selection, "\n") .. "\n"
    system_prompt = system_prompt .. "--- SUFFIX      " .. string.rep("-", 40) .. "\n"
    system_prompt = system_prompt .. table.concat(suffix, "\n") .. "\n"

    messages = { { role = "system", content = system_prompt } }
  end

  local user_content = ""
  if inst and #inst > 0 then
    user_content = "INSTRUCTION: " .. inst
  end
  table.insert(messages, { role = "user", content = user_content })

  return messages
end

--- Send a curl request for instruct
local function send_curl(req_id, request, config, on_stdout, on_exit)
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

  if config.model_inst and #config.model_inst > 0 then
    request.model = config.model_inst
  end
  if config.api_key and #config.api_key > 0 then
    table.insert(curl_args, "--header")
    table.insert(curl_args, "Authorization: Bearer " .. config.api_key)
  end

  local request_json = vim.fn.json_encode(request)
  local job = vim.fn.jobstart(curl_args, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdout_buffered = false,
  })

  if job and job > 0 then
    vim.fn.chansend(job, request_json)
    vim.fn.chanclose(job, "stdin")
  end

  return job
end

--- Update the position of a request's extmark range
local function update_pos(req)
  local extmark_pos = vim.api.nvim_buf_get_extmark_by_id(req.bufnr, ns_inst, req.extmark, {})
  if #extmark_pos == 0 then
    return
  end
  local extmark_line = extmark_pos[1] + 1
  req.range[2] = extmark_line + req.range[2] - req.range[1]
  req.range[1] = extmark_line
end

--- Update the virtual text status display for a request
local function update_status(id, status, config)
  if not M.reqs[id] then
    return
  end

  local req = M.reqs[id]
  req.status = status
  update_pos(req)

  -- remove old virt extmark
  if req.extmark_virt ~= -1 then
    pcall(vim.api.nvim_buf_del_extmark, req.bufnr, ns_inst, req.extmark_virt)
    req.extmark_virt = -1
  end

  local inst_trunc = req.inst
  if #inst_trunc > 128 then
    inst_trunc = inst_trunc:sub(1, 128) .. "..."
  end

  local sep = "====================================="
  local hl = ""
  local virt_lines = {}

  if status == "ready" then
    hl = "llama_hl_inst_virt_ready"
    virt_lines = { { { sep, hl } } }
    for _, line in ipairs(vim.split(req.result, "\n", { plain = true })) do
      table.insert(virt_lines, { { line, hl } })
    end
  elseif status == "proc" then
    hl = "llama_hl_inst_virt_proc"
    virt_lines = {
      { { sep, hl } },
      { { string.format("Endpoint:    %s", config.endpoint_inst), hl } },
      { { string.format("Model:       %s", config.model_inst), hl } },
      { { string.format("Instruction: %s", inst_trunc), hl } },
      { { "Processing ...", hl } },
    }
  elseif status == "gen" then
    local preview = req.result:gsub(".*\n%s*", "")
    if #req.result == 0 then
      preview = "[thinking]"
    end
    hl = "llama_hl_inst_virt_gen"
    virt_lines = {
      { { sep, hl } },
      { { string.format("Endpoint:    %s", config.endpoint_inst), hl } },
      { { string.format("Model:       %s", config.model_inst), hl } },
      { { string.format("Instruction: %s", inst_trunc), hl } },
      { { string.format("Generating:  %4d tokens | %s", req.n_gen, preview), hl } },
    }
  end

  if #virt_lines > 0 then
    table.insert(virt_lines, { { sep, hl } })
    req.extmark_virt = vim.api.nvim_buf_set_extmark(req.bufnr, ns_inst, req.range[2] - 1, 0, {
      virt_lines = virt_lines,
    })
  end
end

--- Remove a request and clean up extmarks/job
local function remove_req(id)
  local req = M.reqs[id]
  if not req then
    return
  end

  pcall(vim.api.nvim_buf_del_extmark, req.bufnr, ns_inst, req.extmark)
  if req.extmark_virt ~= -1 then
    pcall(vim.api.nvim_buf_del_extmark, req.bufnr, ns_inst, req.extmark_virt)
  end
  if req.job then
    pcall(vim.fn.jobstop, req.job)
  end

  M.reqs[id] = nil
end

--- Parse streaming SSE response chunks
local function parse_response(lines)
  local content = ""
  for _, line in ipairs(lines) do
    if #line > 6 and line:sub(1, 6) == "data: " then
      line = line:sub(7)
    end
    if line == "" or line:match("^%s*$") then
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
      elseif choices[1].message and choices[1].message.content then
        local delta = choices[1].message.content
        if type(delta) == "string" then
          content = content .. delta
        end
      end
    end
    ::continue::
  end
  return content
end

--- Send the actual instruct generation request
function M.send(req_id, messages, config)
  debug.log("inst_send")

  local request = {
    id_slot = req_id,
    messages = messages,
    min_p = 0.1,
    temperature = 0.1,
    samplers = { "min_p", "temperature" },
    stream = true,
    cache_prompt = true,
  }

  local req = M.reqs[req_id]

  req.job = send_curl(req_id, request, config, function(_, data, _)
    local content = parse_response(data)
    if not M.reqs[req_id] then
      return
    end
    if #content > 0 then
      req.result = req.result .. content
    end
    req.n_gen = req.n_gen + 1
    vim.schedule(function()
      update_status(req_id, "gen", config)
    end)
  end, function(_, exit_code, _)
    if exit_code ~= 0 then
      vim.schedule(function()
        vim.notify("llama.lua: instruct job failed with exit code " .. exit_code, vim.log.levels.WARN)
      end)
      remove_req(req_id)
      return
    end
    if not M.reqs[req_id] then
      return
    end
    vim.schedule(function()
      update_status(req_id, "ready", config)
      -- add assistant response for continuation
      table.insert(req.inst_prev, { role = "assistant", content = req.result })
    end)
  end)
end

--- Main entry: visual selection -> prompt for instruction -> send
function M.instruct(l0, l1, config)
  local req_id = M.req_id
  M.req_id = M.req_id + 1

  -- send warmup request while user types instruction
  local warmup_messages = M.build(l0, l1, "", nil, config)
  local warmup_request = {
    id_slot = req_id,
    messages = warmup_messages,
    samplers = {},
    n_predict = 0,
    stream = false,
    cache_prompt = true,
    response_fields = { "" },
  }
  send_curl(req_id, warmup_request, config, function() end, function() end)

  -- prompt user
  local inst = vim.fn.input("Instruction: ")
  if inst == "" then
    return
  end

  debug.log("inst_send | " .. inst)

  local bufnr = vim.api.nvim_get_current_buf()

  local req = {
    id = req_id,
    bufnr = bufnr,
    range = { l0, l1 },
    status = "proc",
    result = "",
    inst = inst,
    inst_prev = {},
    job = nil,
    n_gen = 0,
    extmark = -1,
    extmark_virt = -1,
  }

  M.reqs[req_id] = req

  -- highlight selected text
  req.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns_inst, l0 - 1, 0, {
    end_row = l1 - 1,
    end_col = #vim.fn.getline(l1),
    hl_group = "llama_hl_inst_src",
  })

  update_status(req_id, "proc", config)

  req.inst_prev = M.build(l0, l1, inst, nil, config)
  M.send(req_id, req.inst_prev, config)
end

--- Accept: replace selection with result
function M.accept(config)
  local line = vim.fn.line(".")

  for _, req in pairs(M.reqs) do
    if req.status == "ready" then
      update_pos(req)
      if line >= req.range[1] and line <= req.range[2] then
        local result_lines = vim.split(req.result, "\n", { plain = true })
        -- remove trailing empty lines
        while #result_lines > 0 and result_lines[#result_lines] == "" do
          result_lines[#result_lines] = nil
        end

        local id = req.id
        local bufnr = req.bufnr
        local l0, l1 = req.range[1], req.range[2]
        remove_req(id)

        vim.api.nvim_buf_set_lines(bufnr, l0 - 1, l1, false, result_lines)
        return
      end
    end
  end

  -- not on an active request — pass through Tab
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
end

--- Cancel the request under cursor
function M.cancel()
  local line = vim.fn.line(".")
  for _, req in pairs(M.reqs) do
    update_pos(req)
    if line >= req.range[1] and line <= req.range[2] then
      remove_req(req.id)
      return
    end
  end
end

--- Rerun the request under cursor
function M.rerun(config)
  local lnum = vim.fn.line(".")
  for _, req in pairs(M.reqs) do
    update_pos(req)
    if req.status == "ready" and lnum >= req.range[1] and lnum <= req.range[2] then
      debug.log("inst_rerun")
      req.result = ""
      req.status = "proc"
      req.n_gen = 0
      -- remove the last assistant message
      if #req.inst_prev > 0 then
        table.remove(req.inst_prev)
      end
      update_status(req.id, "proc", config)
      M.send(req.id, req.inst_prev, config)
      return
    end
  end
end

--- Continue with a new instruction on the same request
function M.continue(config)
  local lnum = vim.fn.line(".")
  for _, req in pairs(M.reqs) do
    update_pos(req)
    if req.status == "ready" and lnum >= req.range[1] and lnum <= req.range[2] then
      local inst = vim.fn.input("Next instruction: ")
      if inst == "" then
        return
      end
      debug.log("inst_continue | " .. inst)
      req.result = ""
      req.status = "proc"
      req.inst = inst
      req.n_gen = 0
      update_status(req.id, "proc", config)
      req.inst_prev = M.build(req.range[1], req.range[2], inst, req.inst_prev, config)
      M.send(req.id, req.inst_prev, config)
      return
    end
  end
end

return M
