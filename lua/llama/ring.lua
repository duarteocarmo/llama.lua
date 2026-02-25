--- Ring buffer for extra context chunks
local util = require("llama.util")
local debug = require("llama.debug")

local M = {}

M.chunks = {} -- current chunks used as extra context
M.queued = {} -- chunks queued to be sent
M.n_evict = 0

--- Pick a chunk from text and queue it
---@param text string[] lines
---@param no_mod boolean skip modified/non-file buffers
---@param do_evict boolean evict similar chunks
---@param config table
function M.pick_chunk(text, no_mod, do_evict, config)
  if no_mod then
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].modified or not vim.bo[bufnr].buflisted or vim.fn.filereadable(vim.fn.expand("%")) == 0 then
      return
    end
  end

  if config.ring_n_chunks <= 0 then
    return
  end

  if #text < 3 then
    return
  end

  local chunk
  if #text + 1 < config.ring_chunk_size then
    chunk = text
  else
    local l0 = util.rand(1, math.max(1, #text - math.floor(config.ring_chunk_size / 2)))
    local l1 = math.min(l0 + math.floor(config.ring_chunk_size / 2), #text)
    chunk = vim.list_slice(text, l0, l1)
  end

  local chunk_str = table.concat(chunk, "\n") .. "\n"

  -- check duplicates
  for _, c in ipairs(M.chunks) do
    if vim.deep_equal(c.data, chunk) then
      return
    end
  end
  for _, c in ipairs(M.queued) do
    if vim.deep_equal(c.data, chunk) then
      return
    end
  end

  -- evict similar from queued
  for i = #M.queued, 1, -1 do
    if util.chunk_sim(M.queued[i].data, chunk) > 0.9 then
      if do_evict then
        table.remove(M.queued, i)
        M.n_evict = M.n_evict + 1
      else
        return
      end
    end
  end

  -- evict similar from chunks
  for i = #M.chunks, 1, -1 do
    if util.chunk_sim(M.chunks[i].data, chunk) > 0.9 then
      if do_evict then
        table.remove(M.chunks, i)
        M.n_evict = M.n_evict + 1
      else
        return
      end
    end
  end

  if #M.queued >= 16 then
    table.remove(M.queued, 1)
  end

  table.insert(M.queued, {
    data = chunk,
    str = chunk_str,
    time = vim.loop.hrtime(),
    filename = vim.fn.expand("%"),
  })
end

--- Get extra context for FIM requests
function M.get_extra()
  local extra = {}
  for _, chunk in ipairs(M.chunks) do
    table.insert(extra, {
      text = chunk.str,
      time = chunk.time,
      filename = chunk.filename,
    })
  end
  return extra
end

--- Process queued chunks - called periodically
function M.update(config, t_last_move)
  -- only update in normal mode or if cursor hasn't moved for a while
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "n" then
    local elapsed = (vim.loop.hrtime() - t_last_move) / 1e9
    if elapsed < 3.0 then
      return
    end
  end

  if #M.queued == 0 then
    return
  end

  -- move first queued to ring
  if #M.chunks >= config.ring_n_chunks then
    table.remove(M.chunks, 1)
  end

  table.insert(M.chunks, table.remove(M.queued, 1))

  -- send async warmup request with new extra context
  local extra = M.get_extra()

  local request = {
    id_slot = 0,
    input_prefix = "",
    input_suffix = "",
    input_extra = extra,
    prompt = "",
    n_predict = 0,
    temperature = 0.0,
    samplers = {},
    stream = false,
    cache_prompt = true,
    t_max_prompt_ms = 1,
    t_max_predict_ms = 1,
    response_fields = { "" },
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
  local job = vim.fn.jobstart(curl_args, { detach = true })
  if job > 0 then
    vim.fn.chansend(job, request_json)
    vim.fn.chanclose(job, "stdin")
  end
end

return M
