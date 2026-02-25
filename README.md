# 🦙 llama.lua

**This is a shameless, dumb copy of [llama.vim](https://github.com/ggml-org/llama.vim) rewritten in Lua for Neovim.**

Why? Because I wanted debounced completions (so the plugin stops firing on every single keystroke) and non-blocking ghost text rendering. That's literally it. All credit goes to the [llama.vim](https://github.com/ggml-org/llama.vim) authors — this is their plugin with a `.lua` extension and one extra feature.

## What's different from llama.vim?

1. **Debounce** (`auto_fim_debounce_ms`, default 300ms) — completions only fire after you stop typing, not on every keystroke
2. **Non-blocking** — cache lookups and ghost text rendering are deferred via `vim.schedule()`, HTTP requests pipe JSON through stdin asynchronously instead of stuffing it into command-line args
3. **Lua** — it's Lua, so it plugs into the Neovim ecosystem natively (lazy.nvim, etc.)

Everything else is the same: FIM completion, LRU cache, ring buffer context, speculative pre-fetching, accept full/line/word.

## Requirements

- Neovim ≥ 0.9
- `curl` in PATH
- A running [llama.cpp](https://github.com/ggml-org/llama.cpp) server with FIM support

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "duarteocarmo/llama.lua",
  opts = {
    -- all options are optional, these are just examples
    endpoint_fim = "http://127.0.0.1:8012/infill",
    auto_fim_debounce_ms = 300,
  },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "duarteocarmo/llama.lua",
  config = function()
    require("llama").setup({
      auto_fim_debounce_ms = 300,
    })
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'duarteocarmo/llama.lua'

" in your init.lua or after/plugin:
lua require("llama").setup()
```

### Manual

Clone into your Neovim packages directory:

```bash
git clone https://github.com/duarteocarmo/llama.lua \
  ~/.local/share/nvim/site/pack/plugins/start/llama.lua
```

Then in your `init.lua`:

```lua
require("llama").setup()
```

## Configuration

Every option with its default value:

```lua
require("llama").setup({
  -- server
  endpoint_fim           = "http://127.0.0.1:8012/infill",
  endpoint_inst          = "http://127.0.0.1:8012/v1/chat/completions",
  model_fim              = "",
  model_inst             = "",
  api_key                = "",

  -- context
  n_prefix               = 256,      -- lines before cursor for local prefix
  n_suffix               = 64,       -- lines after cursor for local suffix
  n_predict              = 128,      -- max tokens to predict
  stop_strings           = {},

  -- timing
  t_max_prompt_ms        = 500,
  t_max_predict_ms       = 1000,

  -- behavior
  show_info              = 2,        -- 0=off, 1=statusline, 2=inline
  auto_fim               = true,     -- auto-trigger on cursor move
  auto_fim_debounce_ms   = 300,      -- ⭐ debounce delay (set 0 to disable)
  max_line_suffix        = 8,        -- don't auto-trigger if this many chars after cursor
  max_cache_keys         = 250,

  -- ring buffer (extra context)
  ring_n_chunks          = 16,       -- max extra context chunks (0 to disable)
  ring_chunk_size        = 64,       -- lines per chunk
  ring_scope             = 1024,     -- range around cursor for gathering chunks
  ring_update_ms         = 1000,     -- how often to process queued chunks

  -- keymaps (set to "" to disable any keymap)
  keymap_fim_trigger     = "<C-F>",
  keymap_fim_accept_full = "<Tab>",
  keymap_fim_accept_line = "<S-Tab>",
  keymap_fim_accept_word = "<C-B>",
  keymap_debug_toggle    = "<leader>lld",

  enable_at_startup      = true,
})
```

## Commands

| Command               | Description                         |
|-----------------------|-------------------------------------|
| `:LlamaEnable`        | Enable the plugin                   |
| `:LlamaDisable`       | Disable the plugin                  |
| `:LlamaToggle`        | Toggle enable/disable               |
| `:LlamaToggleAutoFim` | Toggle automatic FIM on cursor move |

## Default keymaps

| Keymap         | Mode   | Action                 |
|----------------|--------|------------------------|
| `<C-F>`        | Insert | Trigger FIM completion |
| `<Tab>`        | Insert | Accept full suggestion |
| `<S-Tab>`      | Insert | Accept first line      |
| `<C-B>`        | Insert | Accept first word      |
| `<leader>lld`  | Normal | Toggle debug pane      |

## About the debounce

The original `llama.vim` fires `llama#fim()` on every `CursorMovedI` event — i.e., on every keystroke. If the server is slow or the network has any latency, this causes ghost text to flicker and wastes requests.

`llama.lua` wraps that in a debounce timer. When you type, it hides any existing suggestion immediately, then waits `auto_fim_debounce_ms` milliseconds. If you type again before the timer fires, it resets. Completions only appear once you pause. Set `auto_fim_debounce_ms = 0` if you want the original llama.vim behavior.

## License

MIT — see [LICENSE](LICENSE).

All the actual completion logic is from [llama.vim](https://github.com/ggml-org/llama.vim) by the [ggml-org](https://github.com/ggml-org) team. This is just a Lua rewrite.
