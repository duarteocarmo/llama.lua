-- plugin entry point, lazy-loaded via require("llama").setup()

-- Set default highlight groups early (before colorscheme may override them).
-- Using `default = true` so users can still override with their own colors.
vim.api.nvim_set_hl(0, "llama_hl_fim_hint", { fg = "#ff772f", default = true })
vim.api.nvim_set_hl(0, "llama_hl_fim_info", { fg = "#77ff2f", default = true })

-- Re-apply after colorscheme changes (mimics Vim's `highlight default` persistence)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("llama_hl", { clear = true }),
  callback = function()
    vim.api.nvim_set_hl(0, "llama_hl_fim_hint", { fg = "#ff772f", default = true })
    vim.api.nvim_set_hl(0, "llama_hl_fim_info", { fg = "#77ff2f", default = true })
  end,
})
