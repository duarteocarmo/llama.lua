#!/bin/bash
curl -s http://127.0.0.1:8012/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"system","content":"You are a code editor. When given code and an instruction, output the modified code only. No explanations."},{"role":"user","content":"```lua\n  filetypes              = {\n    [\"*\"]     = true,\n    yaml      = false,\n    markdown  = false,\n    help      = false,\n    gitcommit = false,\n    gitrebase = false,\n    hgcommit  = false,\n  },\n})\n```\n\nadd the beancount file type as false"}],"n_predict":256,"temperature":0.3,"stream":false}' \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])"
