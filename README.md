# 🦙🌙 llama.lua

Lua rewrite of [llama.vim](https://github.com/ggml-org/llama.vim) for Neovim. Local LLM-assisted code completion via [llama.cpp](https://github.com/ggml-org/llama.cpp).

## Additions

- **Debounced completions** — `auto_fim_debounce_ms` (default 300ms), completions wait until you stop typing
- **Server management** — `server_managed` auto-starts `llama-server`, reuses across instances, stops on exit
- **Filetype filtering** — `filetypes` table for per-filetype control (like copilot.lua)
- **Inline instruct** — visual select + instruction, streams replacement directly into buffer (inspired by gp.nvim), undo with `u`

## Requirements

- Neovim ≥ 0.9
- `curl`
- A running [llama.cpp](https://github.com/ggml-org/llama.cpp) server, or `llama-server` in PATH with `server_managed = true`

## Installation

<details>
<summary>lazy.nvim</summary>

```lua
{
  "duarteocarmo/llama.lua",
  opts = {},
}
```
</details>

<details>
<summary>packer.nvim</summary>

```lua
use {
  "duarteocarmo/llama.lua",
  config = function()
    require("llama").setup()
  end,
}
```
</details>

<details>
<summary>vim-plug</summary>

```vim
Plug 'duarteocarmo/llama.lua'
lua require("llama").setup()
```
</details>

## Configuration

```lua
require("llama").setup({
  endpoint_fim           = "http://127.0.0.1:8012/infill",
  endpoint_inst          = "http://127.0.0.1:8012/v1/chat/completions",
  model_fim              = "",
  model_inst             = "",
  api_key                = "",
  n_prefix               = 256,
  n_suffix               = 64,
  n_predict              = 128,
  stop_strings           = {},
  t_max_prompt_ms        = 500,
  t_max_predict_ms       = 1000,
  show_info              = 2,
  auto_fim               = true,
  max_line_suffix        = 8,
  max_cache_keys         = 250,
  ring_n_chunks          = 16,
  ring_chunk_size        = 64,
  ring_scope             = 1024,
  ring_update_ms         = 1000,
  auto_fim_debounce_ms   = 300,
  server_managed         = false,
  server_args            = { "--fim-qwen-7b-default" },
  filetypes              = {
    ["*"]         = true,
    yaml          = false,
    markdown      = false,
    help          = false,
    gitcommit     = false,
    gitrebase     = false,
    hgcommit      = false,
  },
  keymap_fim_trigger     = "<leader>llf",
  keymap_fim_accept_full = "<Tab>",
  keymap_fim_accept_line = "<S-Tab>",
  keymap_fim_accept_word = "<leader>ll]",
  keymap_inst_trigger    = "<leader>lli",
  keymap_debug_toggle    = "<leader>lld",
  enable_at_startup      = true,
})
```

## Commands

| Command | Description |
|---|---|
| `:LlamaEnable` | Enable |
| `:LlamaDisable` | Disable |
| `:LlamaToggle` | Toggle |
| `:LlamaToggleAutoFim` | Toggle auto FIM |
| `:LlamaInstruct` | Instruct (visual selection) |
| `:LlamaServerStart` | Start llama-server |
| `:LlamaServerStop` | Stop llama-server |

## Inspiration

- [llama.vim](https://github.com/ggml-org/llama.vim) — the original, all credit to the authors
- [copilot.lua](https://github.com/zbirenbaum/copilot.lua) — filetype filtering, non-blocking ghost text
- [gp.nvim](https://github.com/Robitx/gp.nvim) — inline replace instruct pattern

## License

MIT
