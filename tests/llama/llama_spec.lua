describe("llama", function()
  local llama = require("llama")
  local cache = require("llama.cache")
  local util = require("llama.util")

  describe("setup", function()
    it("uses defaults", function()
      llama.setup({ enable_at_startup = false })
      assert.equals("http://127.0.0.1:8012/infill", llama.config.endpoint_fim)
      assert.equals(300, llama.config.auto_fim_debounce_ms)
      assert.equals(128, llama.config.n_predict)
      assert.equals("<leader>llf", llama.config.keymap_fim_trigger)
      assert.equals("<leader>ll]", llama.config.keymap_fim_accept_word)
      assert.equals("<leader>lli", llama.config.keymap_inst_trigger)
    end)

    it("merges user config", function()
      llama.setup({
        enable_at_startup = false,
        auto_fim_debounce_ms = 500,
        n_predict = 64,
      })
      assert.equals(500, llama.config.auto_fim_debounce_ms)
      assert.equals(64, llama.config.n_predict)
    end)
  end)

  describe("cache", function()
    before_each(function()
      cache.clear()
    end)

    it("insert and get", function()
      cache.insert("key1", "val1", 10)
      assert.equals("val1", cache.get("key1"))
    end)

    it("returns nil for missing key", function()
      assert.is_nil(cache.get("missing"))
    end)

    it("evicts LRU entry", function()
      cache.insert("a", "1", 2)
      cache.insert("b", "2", 2)
      cache.insert("c", "3", 2) -- evicts "a"
      assert.is_nil(cache.get("a"))
      assert.equals("2", cache.get("b"))
      assert.equals("3", cache.get("c"))
    end)
  end)

  describe("util", function()
    it("chunk_sim identical chunks", function()
      local c = { "hello world", "foo bar" }
      assert.equals(1.0, util.chunk_sim(c, c))
    end)

    it("chunk_sim different chunks", function()
      local c0 = { "hello world" }
      local c1 = { "completely different text here" }
      local sim = util.chunk_sim(c0, c1)
      assert.is_true(sim < 0.5)
    end)

    it("get_indent", function()
      assert.equals(4, util.get_indent("    hello"))
      assert.equals(0, util.get_indent("hello"))
    end)
  end)
end)
