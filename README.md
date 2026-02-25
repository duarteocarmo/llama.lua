# 🦙🌙 llama.lua

Dumb Lua rewrite of [llama.vim](https://github.com/ggml-org/llama.vim) for Neovim. Local LLM-assisted FIM code completion via [llama.cpp](https://github.com/ggml-org/llama.cpp).

All credit to the [llama.vim](https://github.com/ggml-org/llama.vim) authors. I just wanted debounce.

## What's different

One extra config option: `auto_fim_debounce_ms` (default `300`). Completions wait until you stop typing instead of firing on every keystroke. Set to `0` for original llama.vim behavior.

Cache lookups and ghost text rendering are also deferred via `vim.schedule()` so the main thread isn't blocked.

## Requirements

- Neovim ≥ 0.9
- `curl`
- A running [llama.cpp](https://github.com/ggml-org/llama.cpp) server with FIM support

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

<details>
<summary>Manual</summary>

```bash
git clone https://github.com/duarteocarmo/llama.lua \
  ~/.local/share/nvim/site/pack/plugins/start/llama.lua
```

```lua
require("llama").setup()
```
</details>

## Configuration

Same as [llama.vim](https://github.com/ggml-org/llama.vim/blob/master/autoload/llama.vim), plus `auto_fim_debounce_ms`:

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
  show_info              = 2,        -- 0=off, 1=statusline, 2=inline
  auto_fim               = true,
  max_line_suffix        = 8,
  max_cache_keys         = 250,
  ring_n_chunks          = 16,
  ring_chunk_size        = 64,
  ring_scope             = 1024,
  ring_update_ms         = 1000,
  keymap_fim_trigger     = "<leader>llf",
  keymap_fim_accept_full = "<Tab>",
  keymap_fim_accept_line = "<S-Tab>",
  keymap_fim_accept_word = "<leader>ll]",
  keymap_inst_trigger    = "<leader>lli",
  keymap_inst_rerun      = "<leader>llr",
  keymap_inst_continue   = "<leader>llc",
  keymap_inst_accept     = "<Tab>",
  keymap_inst_cancel     = "<Esc>",
  keymap_debug_toggle    = "<leader>lld",
  enable_at_startup      = true,
  auto_fim_debounce_ms   = 300,      -- the only addition (set 0 to disable)
})
```

## Commands

| Command | Description |
|---|---|
| `:LlamaEnable` | Enable |
| `:LlamaDisable` | Disable |
| `:LlamaToggle` | Toggle |
| `:LlamaToggleAutoFim` | Toggle auto FIM |

## License

MIT
