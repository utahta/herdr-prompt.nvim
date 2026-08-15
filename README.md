# herdr-prompt.nvim

Ask a coding agent running in a [herdr](https://herdr.dev) pane about the code in
front of you, without leaving Neovim.

Select some code, type a question, press `<C-s>`. The selection and its file
reference are handed to the agent through the herdr CLI.

The whole UI is a single floating window. What it hands over is *which* code you
are asking about and what you want to know: an agent can read the repository, run
`git diff` and open any file on its own, so that is all it needs.

## Requirements

- Neovim >= 0.10
- [herdr](https://herdr.dev) >= 0.8, with Neovim running inside a herdr pane
- An agent (Claude Code, Codex, ...) running in a pane of the same project

## Installing

##### vim-plug
```viml
Plug 'utahta/herdr-prompt.nvim'
```

##### lazy.nvim
```lua
{ 'utahta/herdr-prompt.nvim' }
```

## Usage

```viml
" ask about the visual selection, or the current line in normal mode
nnoremap <silent> <Leader>p :HerdrPrompt<CR>
xnoremap <silent> <Leader>p :HerdrPrompt<CR>
```

Map it with `:` and not `<Cmd>`. `<Cmd>` bypasses the command line, so the
`'<,'>` range that visual mode inserts never reaches the command and only the
cursor line would be sent.

Inside the float:

| Key | Action |
| --- | --- |
| `<C-s>` | send to the agent (works in insert and normal mode) |
| `q` | cancel |

These keys and the resolved target are shown in the float's footer
(`<C-s> send → wG:p2 [idle] · q cancel`), so the help never becomes part of the
message.

The message is sent as:

````
File: lua/herdr-prompt/init.lua:42-58

```lua
<the selected code>
```

<your message>
````

### Choosing the agent

The target is resolved from `herdr agent list`: agents whose working directory
matches the current git root (or cwd) are candidates. With exactly one match it
is used directly. With several, a picker shows the pane id, the agent status
(`idle` / `working` / `blocked`) and the pane title, so you can avoid
interrupting an agent mid-turn.

If no agent is running in the project, nothing is asked and a warning is shown.

## Configuration

Defaults shown; call `setup()` only to change them.

```lua
require('herdr-prompt').setup({
  -- true  -> `herdr agent prompt`: submit the message right away.
  -- false -> `herdr pane send-text`: only type it into the agent's input, so an
  --          in-flight turn is not interrupted.
  submit = true,

  -- Attach vim.diagnostic entries overlapping the selection. Off by default
  -- because it relies on diagnostics being published to vim.diagnostic, which
  -- not every completion or LSP setup does.
  include_diagnostics = false,

  -- Float size: a fraction of the editor when < 1, an absolute count otherwise.
  -- The float opens one line tall and grows with the message, so `height` is the
  -- ceiling rather than the starting size; beyond it the message scrolls. It is
  -- also capped at half the screen so a short terminal still shows the code.
  width = 0.6,
  height = 10,

  -- Mark the lines being sent while the float is open.
  highlight_selection = true,
  sign_text = '▌',

  keys = {
    send = '<C-s>',
    cancel = 'q',
  },
})
```

## License

MIT
