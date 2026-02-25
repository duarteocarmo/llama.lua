--- LRU cache for FIM completions
local M = {}

M.data = {}
M.lru_order = {}

function M.insert(key, value, max_keys)
  if #vim.tbl_keys(M.data) > (max_keys - 1) then
    local lru_key = M.lru_order[1]
    M.data[lru_key] = nil
    table.remove(M.lru_order, 1)
  end

  M.data[key] = value

  -- Remove existing and re-add at end
  for i = #M.lru_order, 1, -1 do
    if M.lru_order[i] == key then
      table.remove(M.lru_order, i)
      break
    end
  end
  M.lru_order[#M.lru_order + 1] = key
end

function M.get(key)
  if M.data[key] == nil then
    return nil
  end

  -- Update LRU order
  for i = #M.lru_order, 1, -1 do
    if M.lru_order[i] == key then
      table.remove(M.lru_order, i)
      break
    end
  end
  M.lru_order[#M.lru_order + 1] = key

  return M.data[key]
end

function M.clear()
  M.data = {}
  M.lru_order = {}
end

return M
