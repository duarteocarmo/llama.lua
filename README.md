# 🦙 llama.lua

**This is a shameless, dumb copy of [llama.vim](https://github.com/ggml-org/llama.vim) rewritten in Lua for Neovim.**

Why? Because I wanted debounced completions (so the plugin stops firing on every single keystroke) and non-blocking ghost text rendering. That's literally it. All credit goes to the [llama.vim](https://github.com/ggml-org/llama.vim) authors — this is their plugin with a `.lua` extension and one extra config option.

## What's different from llama.vim?

One config option: **`auto_fim_debounce_ms`** (default `300`).

The original `llama.vim` fires `llama#fim()` on every `CursorMovedI` event — i.e., on every keystroke. If the server is slow or the network has any latency, this causes ghost text to flicker and wastes requests. `llama.lua` wraps that in a debounce timer: when you type, it hides any existing suggestion immediately, then waits `auto_fim_debounce_ms` milliseconds. If you type again before the timer fires, it resets. Completions only appear once you pause. Set `auto_fim_debounce_ms = 0` to get the original llama.vim behavior.

Additionally, cache lookups and ghost text rendering are deferred via `vim.schedule()`, and HTTP request bodies are piped through stdin instead of command-line args, so the main thread isn't blocked.

## Requirements

- Neovim ≥ 0.9
- `curl` in PATH
- A running [llama.cpp](https://github.com/ggml-org/llama.cpp) server with FIM support (see the [llama.vim README](https://github.com/ggml-org/llama.vim#llamacpp-setup) for server setup)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "duarteocarmo/llama.lua",
  opts = {
    -- all options are optional
  },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "duarteocarmo/llama.lua",
  config = function()
    require("llama").setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'duarteocarmo/llama.lua'
lua require("llama").setup()
```

### Manual

```bash
git clone https://github.com/duarteocarmo/llama.lua \
  ~/.local/share/nvim/site/pack/plugins/start/llama.lua
```

Then in your `init.lua`:

```lua
require("llama").setup()
```

## Configuration

Same options as [llama.vim](https://github.com/ggml-org/llama.vim), plus `auto_fim_debounce_ms`. All defaults match llama.vim:

```lua
require("llama").setup({
  -- server
  endpoint_fim           = "http://127.0.0.1:8012/infill",
  endpoint_inst          = "http://127.0.0.1:8012/v1/chat/completions",
  model_fim              = "",
  model_inst             = "",
  api_key                = "",

  -- context
  n_prefix               = 256,
  n_suffix               = 64,
  n_predict              = 128,
  stop_strings           = {},

  -- timing
  t_max_prompt_ms        = 500,
  t_max_predict_ms       = 1000,

  -- behavior
  show_info              = 2,        -- 0=off, 1=statusline, 2=inline
  auto_fim               = true,
  max_line_suffix        = 8,
  max_cache_keys         = 250,

  -- ring buffer (extra context)
  ring_n_chunks          = 16,
  ring_chunk_size        = 64,
  ring_scope             = 1024,
  ring_update_ms         = 1000,

  -- FIM keymaps
  keymap_fim_trigger     = "<leader>llf",
  keymap_fim_accept_full = "<Tab>",
  keymap_fim_accept_line = "<S-Tab>",
  keymap_fim_accept_word = "<leader>ll]",

  -- instruct keymaps
  keymap_inst_trigger    = "<leader>lli",
  keymap_inst_rerun      = "<leader>llr",
  keymap_inst_continue   = "<leader>llc",
  keymap_inst_accept     = "<Tab>",
  keymap_inst_cancel     = "<Esc>",

  -- debug
  keymap_debug_toggle    = "<leader>lld",

  enable_at_startup      = true,

  -- ⭐ the only option not in llama.vim
  auto_fim_debounce_ms   = 300,      -- set 0 to disable (original llama.vim behavior)
})
```

## Commands

| Command               | Description                         |
|-----------------------|-------------------------------------|
| `:LlamaEnable`        | Enable the plugin                   |
| `:LlamaDisable`       | Disable the plugin                  |
| `:LlamaToggle`        | Toggle enable/disable               |
| `:LlamaToggleAutoFim` | Toggle automatic FIM on cursor move |

## License

MIT — see [LICENSE](LICENSE).

All the actual logic is from [llama.vim](https://github.com/ggml-org/llama.vim) by the [ggml-org](https://github.com/ggml-org) team. This is just a Lua rewrite with debounce.
