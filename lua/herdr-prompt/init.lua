-- Ask the coding agents running in this herdr workspace about the code in front
-- of you.
--
-- The whole UI is one floating window placed just below the selection, with the
-- selection highlighted behind it: type a message, press <C-s>, and the code
-- plus its file reference is handed to the agent through the herdr CLI. Nothing
-- else is shown, because everything else the agent can find out on its own.
--
-- The workspace is the boundary. An agent one workspace over would answer into a
-- pane that is not on screen, which is the one thing this exists to avoid, so it
-- is not a candidate even when it sits in the same repository.

local M = {}

-- Naming a file for an agent is its own concern, with no bearing on anything
-- below: see lua/herdr-prompt/path.lua.
local path = require('herdr-prompt.path')

local defaults = {
  -- true  -> `herdr agent prompt`, which submits the message immediately.
  -- false -> `herdr pane send-text`, which only types it into the agent's
  --          input so an in-flight turn is not interrupted.
  submit = true,

  -- Attach vim.diagnostic entries that overlap the selection. Off by default
  -- because it relies on diagnostics being published to vim.diagnostic, which
  -- not every completion or LSP setup does; where they are not, it attaches
  -- nothing at all.
  include_diagnostics = false,

  -- Float size: a fraction of the editor when < 1, an absolute count otherwise.
  -- The float opens one line tall and grows with the message, so height is the
  -- ceiling rather than the starting size; past it the message scrolls. Keeping
  -- the ceiling low leaves more of the selection visible.
  width = 0.6,
  height = 10,

  -- Display cells to allow for a pane title in the agent picker. Titles come
  -- from the agent and can be long enough to stretch the picker across the whole
  -- screen, since its width follows the longest row.
  title_width = 40,

  -- Mark the lines being sent while the float is open: a background tint via
  -- the HerdrPromptSelection highlight, plus a sign in the gutter. Set to false
  -- to leave the buffer untouched.
  highlight_selection = true,
  -- Gutter marker for those lines. Set to nil for a tint with no sign.
  sign_text = '▌',

  -- Each entry takes a string or a list of equivalents, of which the first is
  -- what the footer shows.
  keys = {
    -- Message float.
    send = '<C-s>',
    -- Also closes the agent picker. <Esc> is only bound in normal mode, so the
    -- first one leaves insert mode and the next one gives up on the message.
    cancel = { 'q', '<Esc>' },
    -- Agent picker, shown when more than one agent is running. The control-key
    -- aliases exist because an active IME swallows <Space> and plain letters
    -- before Neovim sees them, while control keys pass through.
    mark = { '<Space>', '<C-x>' },
    mark_all = { 'a', '<C-a>' },
    confirm = '<CR>',
  },
}

local config = vim.deepcopy(defaults)

local namespace = vim.api.nvim_create_namespace('herdr-prompt')

-- Linked to DiffChange rather than Visual: on a 256-colour terminal without
-- 'termguicolors', Visual's ctermbg is often a near-background grey that is
-- invisible on dark colorschemes. A sign in the gutter backs it up, so the range
-- is legible even where the background tint is not.
vim.api.nvim_set_hl(0, 'HerdrPromptSelection', { default = true, link = 'DiffChange' })
vim.api.nvim_set_hl(0, 'HerdrPromptSign', { default = true, link = 'DiffChange' })

-- Marks an agent the file does not sit under, where the message has to name the
-- file by absolute path. Linked to an error group rather than a comment one
-- because it is a mismatch worth noticing before sending, not decoration.
vim.api.nvim_set_hl(0, 'HerdrPromptOutside', { default = true, link = 'DiagnosticError' })

local MARKER = '[outside cwd]'

function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  -- A key option is a list, and tbl_deep_extend merges lists by index: passing
  -- `cancel = { 'x' }` would otherwise leave the default's <Esc> sitting behind
  -- it. Whatever the caller gave replaces the default outright, so a shorter list
  -- really is shorter.
  for name, spec in pairs(opts.keys or {}) do
    config.keys[name] = spec
  end
end

local function herdr(args)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out, '\n')
  end
  return table.concat(out, '\n')
end

-- The workspace this Neovim sits in, which is what bounds the candidates.
--
-- Whether it is in a pane at all only the environment can answer. `herdr pane
-- current` with no argument reports whichever pane is focused, so from a Neovim
-- started outside herdr it would hand back a stranger's workspace instead of
-- admitting there is none.
--
-- Which workspace that pane is in is asked of herdr rather than read from
-- HERDR_WORKSPACE_ID, because the env var is a snapshot from when the process
-- started and `herdr pane move --workspace` can move the pane afterwards. The
-- env var is the fallback.
local function current_workspace()
  local pane = vim.env.HERDR_PANE_ID
  if not pane or pane == '' then
    return nil
  end

  local raw = herdr({ 'pane', 'current', '--pane', pane })
  if raw then
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok then
      local id = vim.tbl_get(decoded, 'result', 'pane', 'workspace_id')
      if type(id) == 'string' and id ~= '' then
        return id
      end
    end
  end

  local id = vim.env.HERDR_WORKSPACE_ID
  return id ~= '' and id or nil
end

-- Candidates are the agents in this workspace, and nothing else. `elsewhere`
-- carries the ones beyond it that hold this file under their directory, so a
-- warning can say where the answer would have gone without sending it there.
local function resolve_target(subject)
  local workspace = current_workspace()
  if not workspace then
    return nil, 'Neovim is not running in a herdr pane'
  end

  local raw, err = herdr({ 'agent', 'list' })
  if not raw then
    return nil, err or 'could not run `herdr agent list`'
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return nil, 'could not parse `herdr agent list` output'
  end
  local all = vim.tbl_get(decoded, 'result', 'agents')
  if type(all) ~= 'table' then
    return nil, 'herdr reported no agents'
  end

  -- Two lists rather than a sort, so the agents that can reach the file come
  -- first while each group keeps the order herdr reported.
  local near, far, elsewhere = {}, {}, {}
  for _, agent in ipairs(all) do
    if agent.workspace_id == workspace then
      table.insert(path.outside(agent, subject.resolved) and far or near, agent)
    elseif path.relative(agent, subject.resolved) then
      table.insert(elsewhere, agent)
    end
  end
  vim.list_extend(near, far)

  return { agents = near, workspace = workspace, elsewhere = elsewhere }
end

-- Names the workspace that was searched, and points at an agent beyond it when
-- one holds this file, since "no agent" is otherwise hard to act on.
local function no_agent_message(target)
  local message = 'no agent in workspace ' .. target.workspace
  if #target.elsewhere == 0 then
    return message
  end

  local ids = {}
  for i = 1, math.min(2, #target.elsewhere) do
    table.insert(ids, target.elsewhere[i].pane_id)
  end
  return message .. ' · this file is in the cwd of ' .. table.concat(ids, ', ')
end

-- The command always passes a range; without a visual selection line1 == line2,
-- which makes the current line the subject.
local function selected_lines(opts)
  local first = opts.line1 or vim.fn.line('.')
  local last = math.max(first, opts.line2 or first)
  return first, last, vim.api.nvim_buf_get_lines(0, first - 1, last, false)
end

local function diagnostics_between(first, last)
  local items = {}
  for _, d in ipairs(vim.diagnostic.get(0)) do
    local line = d.lnum + 1
    if line >= first and line <= last then
      local severity = vim.diagnostic.severity[d.severity] or '?'
      local message = (d.message or ''):gsub('%s+', ' ')
      table.insert(items, string.format('- L%d %s: %s', line, severity, message))
    end
  end
  return items
end

local function range_label(first, last)
  return first == last and tostring(first) or string.format('%d-%d', first, last)
end

-- Key options accept either a single lhs or a list of equivalents.
local function key_list(spec)
  return type(spec) == 'table' and spec or { spec }
end

local function key_label(spec)
  return key_list(spec)[1]
end

local function dimension(value, total, minimum)
  local n = value <= 1 and (total * value) or value
  return math.max(minimum, math.floor(n))
end

-- `subject` is captured before the float opens: once focus moves to the float,
-- '%:p' and &filetype would describe the scratch buffer instead of the code.
--
-- The path is relative to the agent's own directory wherever that is possible,
-- which is both what the agent would write itself and free of the home directory,
-- and falls back to the absolute path only when the file sits outside it.
local function build_payload(message, subject, agent)
  local out = {
    string.format(
      'File: %s:%s',
      path.relative(agent, subject.resolved) or subject.path,
      range_label(subject.first, subject.last)
    ),
    '',
    '```' .. subject.filetype,
  }
  vim.list_extend(out, subject.lines)
  table.insert(out, '```')

  if #subject.diagnostics > 0 then
    table.insert(out, '')
    table.insert(out, 'Diagnostics:')
    vim.list_extend(out, subject.diagnostics)
  end

  table.insert(out, '')
  vim.list_extend(out, message)
  return table.concat(out, '\n')
end

-- "claude wG:p2 [idle]". The kind matters as much as the pane once more than
-- one kind of agent is in play.
local function agent_label(agent)
  return string.format('%s %s [%s]', agent.agent or 'agent', agent.pane_id, agent.agent_status or '?')
end

local function verb()
  return config.submit and 'sent to' or 'staged in'
end

-- The payload is built here rather than passed in, because the file reference is
-- relative to the recipient's directory and so differs per agent. The message
-- itself is the same for all of them.
--
-- `quiet` suppresses the per-agent notification so a broadcast can report once.
local function send_to(agent, message, subject, quiet)
  local payload = build_payload(message, subject, agent)
  local args = config.submit and { 'agent', 'prompt', agent.pane_id, payload }
    or { 'pane', 'send-text', agent.pane_id, payload }

  local _, err = herdr(args)
  if err then
    vim.notify('herdr-prompt: ' .. err, vim.log.levels.ERROR)
    return false
  end
  if not quiet then
    vim.notify(string.format('herdr-prompt: %s %s', verb(), agent_label(agent)))
  end
  return true
end

local function send_to_many(agents, message, subject)
  local sent = 0
  for _, agent in ipairs(agents) do
    if send_to(agent, message, subject, true) then
      sent = sent + 1
    end
  end
  vim.notify(string.format('herdr-prompt: %s %d/%d agents', verb(), sent, #agents))
end

-- Cut to display cells rather than bytes or characters: titles are often
-- Japanese, where one character occupies two cells.
local function truncate(s, limit)
  if vim.fn.strdisplaywidth(s) <= limit then
    return s
  end
  local width, keep = 0, 0
  for i = 1, vim.fn.strchars(s) do
    local cell = vim.fn.strdisplaywidth(vim.fn.strcharpart(s, i - 1, 1))
    if width + cell > limit - 1 then -- leave a cell for the ellipsis
      break
    end
    width, keep = width + cell, i
  end
  return vim.fn.strcharpart(s, 0, keep) .. '…'
end

-- The pane title earns its space in the picker: it is what tells two agents of
-- the same kind apart.
--
-- It comes last and takes only the room left over, because rows are not wrapped
-- and the picker can be no wider than the screen: a title long enough to overflow
-- would push whatever follows off the right edge unseen. The marker must not be
-- what is lost, so it goes first and the title is what gives way.
local function picker_label(agent, outside, room)
  local label = agent_label(agent)
  if outside then
    label = label .. '  ' .. MARKER
  end

  local title = agent.terminal_title_stripped
  if not title or title == '' then
    return label
  end

  local budget = math.min(config.title_width, room - vim.fn.strdisplaywidth(label) - 2)
  if budget < 2 then -- not even one cell and the ellipsis
    return label
  end
  return label .. '  ' .. truncate(title, budget)
end

-- Built here rather than delegated to vim.ui.select, whose callback takes a
-- single item and so cannot express "these three". Marks make one UI cover
-- picking one, some, or all of them.
local function pick_agents(agents, subject, on_confirm)
  local marked = {}

  -- What a row's text has to fit in: the window is capped at the screen below,
  -- keeps two cells of padding, and every row carries a two-cell mark in front.
  local room = vim.o.columns - 4 - 2 - 2

  -- Built once here and not in line_at: the rows are rewritten on every mark,
  -- and each label costs a symlink resolve.
  local labels = {}
  for i, agent in ipairs(agents) do
    labels[i] = picker_label(agent, path.outside(agent, subject.resolved), room)
  end

  local function marked_count()
    return vim.tbl_count(marked)
  end

  local function line_at(i)
    return (marked[i] and '✓ ' or '  ') .. labels[i]
  end

  local lines = {}
  for i = 1, #agents do
    lines[i] = line_at(i)
  end

  local function footer_line()
    local n = marked_count()
    -- Spell out the target: "1 marked" and no marks at all both send one agent,
    -- but to a different one, so a bare count would be ambiguous.
    local target = n > 0 and string.format('%d marked', n) or 'this one'
    return string.format(
      ' %s mark · %s all · %s send %s · %s cancel ',
      key_label(config.keys.mark),
      key_label(config.keys.mark_all),
      key_label(config.keys.confirm),
      target,
      key_label(config.keys.cancel)
    )
  end

  local width = vim.fn.strdisplaywidth(footer_line())
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#agents, math.max(3, math.floor((vim.o.lines - vim.o.cmdheight) / 2)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  -- Re-applied after every redraw, because rewriting a line drops the extmarks
  -- sitting on it. The marker is found in the text rather than measured, since
  -- the truncated title before it makes its column differ from row to row.
  local function mark_outside()
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for i = 1, #agents do
      local col = line_at(i):find(MARKER, 1, true)
      if col then
        vim.api.nvim_buf_set_extmark(buf, namespace, i - 1, col - 1, {
          end_col = col - 1 + #MARKER,
          hl_group = 'HerdrPromptOutside',
        })
      end
    end
  end

  mark_outside()

  local function window_config()
    return {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      border = 'rounded',
      style = 'minimal',
      title = ' Send to ',
      title_pos = 'center',
      footer = footer_line(),
      footer_pos = 'center',
    }
  end

  local win = vim.api.nvim_open_win(buf, true, window_config())
  vim.wo[win].cursorline = true
  -- 'wrap' is not one of the options style = 'minimal' resets, so a global
  -- `set wrap` carries over. A wrapped row would break the one-row-per-agent
  -- height and push the last candidates out of the window.
  vim.wo[win].wrap = false

  local function redraw()
    vim.bo[buf].modifiable = true
    for i = 1, #agents do
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { line_at(i) })
    end
    vim.bo[buf].modifiable = false
    mark_outside()
    vim.api.nvim_win_set_config(win, window_config())
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function map(spec, fn, desc)
    for _, lhs in ipairs(key_list(spec)) do
      vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end

  map(config.keys.mark, function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    marked[line] = not marked[line] and true or nil
    redraw()
    -- Advance so a run of agents can be marked without moving separately.
    if line < #agents then
      vim.api.nvim_win_set_cursor(win, { line + 1, 0 })
    end
  end, 'Toggle mark')

  map(config.keys.mark_all, function()
    local all = marked_count() == #agents
    for i = 1, #agents do
      marked[i] = not all and true or nil
    end
    redraw()
  end, 'Toggle all marks')

  map(config.keys.confirm, function()
    local indexes = vim.tbl_keys(marked)
    -- Nothing marked means "just this one", so <CR> stays a single keystroke for
    -- the common case.
    if #indexes == 0 then
      indexes = { vim.api.nvim_win_get_cursor(win)[1] }
    end
    table.sort(indexes)

    local chosen = {}
    for _, i in ipairs(indexes) do
      table.insert(chosen, agents[i])
    end
    close()
    on_confirm(chosen)
  end, 'Send')

  map(config.keys.cancel, close, 'Cancel')
end

-- A lone agent that can reach the file needs no picker. One that cannot goes
-- through it anyway: the message would carry an absolute path into a directory
-- the agent is not working in, and in a workspace of several tabs that agent may
-- not even be on screen, so it is worth a deliberate keystroke.
local function pick_and_send(agents, message, subject)
  if #agents == 1 and not path.outside(agents[1], subject.resolved) then
    return send_to(agents[1], message, subject)
  end
  pick_agents(agents, subject, function(chosen)
    if #chosen == 1 then
      return send_to(chosen[1], message, subject)
    end
    send_to_many(chosen, message, subject)
  end)
end

-- Key help lives in the border footer rather than in the buffer, so it can
-- never end up in the message. Naming the target here also makes it obvious
-- where the message is about to go, and marks the case where it will carry an
-- absolute path, which is on screen for the whole time the message is typed.
local function footer_text(agents, subject)
  local target = #agents == 1 and agent_label(agents[1]) or string.format('%d agents', #agents)
  local chunks = {
    { string.format(' %s send → %s', key_label(config.keys.send), target), 'FloatFooter' },
  }
  if #agents == 1 and path.outside(agents[1], subject.resolved) then
    table.insert(chunks, { ' ' .. MARKER, 'HerdrPromptOutside' })
  end
  table.insert(chunks, { string.format(' · %s cancel ', key_label(config.keys.cancel)), 'FloatFooter' })
  return chunks
end

-- Decide where the float lives, given the tallest it may grow to. Judging on the
-- maximum rather than the current height keeps the placement from flipping
-- around as the float grows while typing.
--
-- Below the selection the top edge is pinned, so growth extends downwards; above
-- it the bottom edge is pinned instead, so growth extends upwards and the
-- selection stays uncovered either way.
--
-- Must run while the code window is still current, because screenpos() is
-- relative to it.
local function float_placement(first, last, max_outer)
  local usable = vim.o.lines - vim.o.cmdheight

  local below = vim.fn.screenpos(0, last, 1).row
  if below > 0 and below + max_outer <= usable then
    return { pin = 'top', row = below }
  end

  local above = vim.fn.screenpos(0, first, 1).row
  if above > 0 and above - 1 - max_outer >= 0 then
    return { pin = 'bottom', bottom = above - 1 }
  end

  -- Selection is scrolled off screen, or the float fits nowhere near it.
  return { pin = 'top', row = math.max(0, math.floor((usable - max_outer) / 2)) }
end

function M.open(opts)
  opts = opts or {}

  local origin_buf = vim.api.nvim_get_current_buf()
  local first, last, lines = selected_lines(opts)
  local path = vim.fn.expand('%:p')
  local subject = {
    -- `path` is left unresolved because it is what the absolute-path fallback
    -- sends, and a symlink is how the file was opened, so it is the name the
    -- agent is likelier to recognise. `resolved` is the one compared against an
    -- agent's directory, and is nil for a buffer with no file at all.
    path = path ~= '' and path or '[No Name]',
    resolved = path ~= '' and vim.fn.resolve(path) or nil,
    filetype = vim.bo.filetype or '',
    first = first,
    last = last,
    lines = lines,
    diagnostics = config.include_diagnostics and diagnostics_between(first, last) or {},
  }

  -- Resolve the target before asking for a message, so a missing agent is
  -- reported before anything is typed.
  local target, err = resolve_target(subject)
  if not target then
    return vim.notify('herdr-prompt: ' .. err, vim.log.levels.ERROR)
  end
  if #target.agents == 0 then
    return vim.notify('herdr-prompt: ' .. no_agent_message(target), vim.log.levels.WARN)
  end
  local agents = target.agents

  local usable = vim.o.lines - vim.o.cmdheight
  local width = dimension(config.width, vim.o.columns, 40)
  -- config.height is the ceiling, not the starting size: the float opens one
  -- line tall and grows with the message. Capped at half the screen, border
  -- included, so a short terminal still shows the code.
  local max_height = math.min(dimension(config.height, usable, 1), math.max(1, math.floor(usable / 2) - 2))
  local placement = float_placement(first, last, max_height + 2)

  -- One extmark per line: line_hl_group covers the whole line reliably, and
  -- sign_text has to be attached line by line to mark the full range.
  if config.highlight_selection then
    for line = first, last do
      vim.api.nvim_buf_set_extmark(origin_buf, namespace, line - 1, 0, {
        line_hl_group = 'HerdrPromptSelection',
        sign_text = config.sign_text,
        sign_hl_group = 'HerdrPromptSign',
      })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'

  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local title = string.format(' Ask agent · %s:%s ', vim.fn.fnamemodify(subject.path, ':t'), range_label(first, last))
  local footer = footer_text(agents, subject)

  -- Rebuilt on every resize: nvim_win_set_config drops anything left out, so
  -- title and footer have to be passed again each time.
  local function window_config(h)
    return {
      relative = 'editor',
      width = width,
      height = h,
      row = placement.pin == 'bottom' and math.max(0, placement.bottom - (h + 2)) or placement.row,
      col = col,
      border = 'rounded',
      style = 'minimal',
      title = title,
      title_pos = 'center',
      footer = footer,
      footer_pos = 'center',
    }
  end

  local win = vim.api.nvim_open_win(buf, true, window_config(1))
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  -- Grow with the message so a one-line question gets a one-line box.
  --
  -- Measured in screen rows, not logical lines: 'wrap' is on, so a long line —
  -- especially one of double-width characters — takes more than one row, and
  -- counting logical lines would leave the start of the message scrolled out of
  -- view. nvim_win_text_height accounts for the wrapping.
  local shown = 1
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local ok, measured = pcall(vim.api.nvim_win_text_height, win, {})
      local rows = ok and measured.all or vim.api.nvim_buf_line_count(buf)
      local wanted = math.max(1, math.min(rows, max_height))
      if wanted ~= shown then
        shown = wanted
        vim.api.nvim_win_set_config(win, window_config(wanted))
      end

      -- Enlarging a window does not reset its scroll position: the view may
      -- still start partway down from when the box was shorter, hiding the
      -- first line. Pull it back to the top whenever everything fits.
      if rows <= wanted then
        vim.api.nvim_win_call(win, function()
          local view = vim.fn.winsaveview()
          if view.topline ~= 1 then
            view.topline = 1
            vim.fn.winrestview(view)
          end
        end)
      end
    end,
  })

  -- Clear the tint however the float goes away, including :q or a window close
  -- that never runs the mappings below.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(origin_buf) then
        vim.api.nvim_buf_clear_namespace(origin_buf, namespace, 0, -1)
      end
    end,
  })

  local function close()
    -- Leave insert mode along with the float. <C-s> works from insert mode, and
    -- what comes next is either the picker, whose buffer is not modifiable, or
    -- the code buffer, which should not be entered in insert mode.
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local message = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Close first: the picker should not be drawn underneath this float.
    close()
    if table.concat(message, ''):gsub('%s', '') == '' then
      return vim.notify('herdr-prompt: empty message, nothing sent', vim.log.levels.WARN)
    end
    pick_and_send(agents, message, subject)
  end

  for _, lhs in ipairs(key_list(config.keys.send)) do
    vim.keymap.set({ 'n', 'i' }, lhs, submit, { buffer = buf, desc = 'Send to agent' })
  end
  for _, lhs in ipairs(key_list(config.keys.cancel)) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true, desc = 'Cancel' })
  end
  vim.cmd('startinsert')
end

return M
