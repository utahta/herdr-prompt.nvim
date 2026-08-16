# herdr-prompt.nvim

Ask one or more coding agents already running in [herdr](https://herdr.dev) panes
about the code in front of you, without switching panes.

Select some code, type a question, press `<C-s>`. The selection and its file
reference are handed to each agent through the herdr CLI.

The whole UI is a single floating window. What it hands over is *which* code you
are asking about and what you want to know: an agent can read the repository, run
`git diff` and open any file on its own, so that is all it needs.

## Requirements

- Neovim >= 0.10
- [herdr](https://herdr.dev) >= 0.8, with Neovim running inside a herdr pane
- An agent (Claude Code, Codex, ...) running in a pane of the same workspace

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
| `q` / `<Esc>` | cancel |

These keys and the resolved target are shown in the float's footer
(`<C-s> send → wG:p2 [idle] · q cancel`), so the help never becomes part of the
message.

Cancelling is bound in normal mode only, so the first `<Esc>` leaves insert mode
and the next one gives up on the message.

The message is sent as:

````
File: lua/herdr-prompt/init.lua:42-58

```lua
<the selected code>
```

<your message>
````

The path is relative to the recipient's own working directory, which is how the
agent would write it itself and keeps the home directory out of the transcript. A
file outside that directory is named absolutely instead.

### Choosing the agent

The candidates are the agents in the same herdr workspace as this Neovim, read
from `herdr agent list`. With exactly one it is used directly. With several, a
picker opens.

The workspace is the boundary, not the repository. An agent one workspace over
would answer into a pane that is not on screen, which is the one thing this is
meant to avoid, so it is never a target — even when it is working in the same
checkout.

| Key | Action |
| --- | --- |
| `j` / `k` | move |
| `<Space>` / `<C-x>` | toggle a mark |
| `a` / `<C-a>` | toggle all marks |
| `<CR>` | send to the marked agents, or to the line under the cursor when none are marked |
| `q` / `<Esc>` | cancel |

The control-key aliases matter with an input method active: an IME swallows
`<Space>` and plain letters before Neovim sees them, while control keys pass
through. So a question can be typed in Japanese and sent without touching the
IME.

Each row carries the agent kind, pane id, status (`idle` / `working` / `blocked`)
and pane title, so an agent can be left alone mid-turn. Marking several sends the
same message to each — one way to put a question to more than one agent and
compare what comes back.

An agent whose working directory the file does not sit under is marked
`[outside cwd]` and sorted last. It stays selectable, since a path outside a
directory can still be read, but the message has to name the file absolutely — so
a lone agent in that state opens the picker instead of being sent to straight
away. The same mark appears in the message float's footer, which is on screen the
whole time the message is being typed.

If no agent is running in the workspace, nothing is asked and a warning names the
workspace it searched, along with the pane of an agent elsewhere that holds this
file when there is one.

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

  -- Every key takes a string or a list of equivalents; the first entry is the one
  -- shown in the footer. A list given here replaces the default rather than
  -- merging into it, so `cancel = { 'q' }` really does drop `<Esc>`.
  keys = {
    -- Message float.
    send = '<C-s>',
    -- Cancelling also applies to the agent picker.
    cancel = { 'q', '<Esc>' },
    -- Agent picker.
    mark = { '<Space>', '<C-x>' },
    mark_all = { 'a', '<C-a>' },
    confirm = '<CR>',
  },
})
```

## Tests

```
nvim --headless -u NONE -l tests/path_spec.lua
```

Covers how a file is named for a given agent, which is the part where a mistake
is silent: the message would name a file that does not exist.

## License

MIT
