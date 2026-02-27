local M = {}

function M.get_indent(str)
  local count = 0
  for i = 1, #str do
    local c = str:sub(i, i)
    if c == "\t" then
      count = count + vim.bo.tabstop
    elseif c == " " then
      count = count + 1
    else
      break
    end
  end
  return count
end

function M.rand(i0, i1)
  return i0 + math.random(0, i1 - i0)
end

function M.chunk_sim(c0, c1)
  local text0 = table.concat(c0, "\n")
  local text1 = table.concat(c1, "\n")

  local tokens0 = {}
  local set0 = {}
  for tok in text0:gmatch("%w+") do
    tokens0[#tokens0 + 1] = tok
    set0[tok] = true
  end

  local tokens1 = {}
  local common = 0
  for tok in text1:gmatch("%w+") do
    tokens1[#tokens1 + 1] = tok
    if set0[tok] then
      common = common + 1
    end
  end

  if (#tokens0 + #tokens1) == 0 then
    return 1.0
  end
  return 2.0 * common / (#tokens0 + #tokens1)
end

function M.sha256(str)
  return vim.fn.sha256(str)
end

return M
