-- Ask a coding agent running in a herdr pane about the code in front of you.
--
-- The whole UI is one floating window placed just below the selection, with the
-- selection highlighted behind it: type a message, press <C-s>, and the code
-- plus its file reference is handed to the agent through the herdr CLI. Nothing
-- else is shown, because everything else the agent can find out on its own.

local M = {}

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

  -- Mark the lines being sent while the float is open: a background tint via
  -- the HerdrPromptSelection highlight, plus a sign in the gutter. Set to false
  -- to leave the buffer untouched.
  highlight_selection = true,
  -- Gutter marker for those lines. Set to nil for a tint with no sign.
  sign_text = '▌',

  keys = {
    send = '<C-s>',
    cancel = 'q',
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

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
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

-- Prefer the git root so that every buffer in a repository resolves to the same
-- project, whichever subdirectory Neovim was started from. Resolved because
-- repositories are often reached through symlinks.
local function project_root()
  local out = vim.fn.systemlist({ 'git', 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
    return vim.fn.resolve(out[1])
  end
  return vim.fn.resolve(vim.fn.getcwd())
end

-- Agents whose working directory is this project. herdr reports both cwd and
-- foreground_cwd; either matching is enough to call it the same project.
local function project_agents()
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

  local root = project_root()
  local matched = {}
  for _, agent in ipairs(all) do
    for _, dir in ipairs({ agent.foreground_cwd, agent.cwd }) do
      if dir and vim.fn.resolve(dir) == root then
        table.insert(matched, agent)
        break
      end
    end
  end
  return matched
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

local function relative_path(root)
  local path = vim.fn.resolve(vim.fn.expand('%:p'))
  if path == '' then
    return '[No Name]'
  end
  if path:sub(1, #root + 1) == root .. '/' then
    return path:sub(#root + 2)
  end
  return path
end

local function range_label(first, last)
  return first == last and tostring(first) or string.format('%d-%d', first, last)
end

local function dimension(value, total, minimum)
  local n = value <= 1 and (total * value) or value
  return math.max(minimum, math.floor(n))
end

-- `subject` is captured before the float opens: once focus moves to the float,
-- '%:p' and &filetype would describe the scratch buffer instead of the code.
local function build_payload(message, subject)
  local out = {
    string.format('File: %s:%s', subject.path, range_label(subject.first, subject.last)),
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

local function send_to(agent, payload)
  local args = config.submit and { 'agent', 'prompt', agent.pane_id, payload }
    or { 'pane', 'send-text', agent.pane_id, payload }

  local _, err = herdr(args)
  if err then
    return vim.notify('herdr-prompt: ' .. err, vim.log.levels.ERROR)
  end
  vim.notify(string.format(
    'herdr-prompt: %s %s',
    config.submit and 'sent to' or 'staged in',
    agent_label(agent)
  ))
end

local function pick_and_send(agents, payload)
  if #agents == 1 then
    return send_to(agents[1], payload)
  end
  vim.ui.select(agents, {
    prompt = 'herdr agent',
    format_item = function(agent)
      -- The pane title is worth the space here: it is what tells two agents of
      -- the same kind apart.
      local title = agent.terminal_title_stripped
      if title and title ~= '' then
        return agent_label(agent) .. '  ' .. title
      end
      return agent_label(agent)
    end,
  }, function(choice)
    if choice then
      send_to(choice, payload)
    end
  end)
end

-- Key help lives in the border footer rather than in the buffer, so it can
-- never end up in the message. Naming the target here also makes it obvious
-- where the message is about to go.
local function footer_text(agents)
  local target = #agents == 1 and agent_label(agents[1]) or string.format('%d agents', #agents)
  return string.format(' %s send → %s · %s cancel ', config.keys.send, target, config.keys.cancel)
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

  -- Resolve the target before asking for a message, so a missing agent is
  -- reported before anything is typed.
  local agents, err = project_agents()
  if not agents then
    return vim.notify('herdr-prompt: ' .. err, vim.log.levels.ERROR)
  end
  if #agents == 0 then
    return vim.notify('herdr-prompt: no agent running in ' .. project_root(), vim.log.levels.WARN)
  end

  local origin_buf = vim.api.nvim_get_current_buf()
  local first, last, lines = selected_lines(opts)
  local subject = {
    path = relative_path(project_root()),
    filetype = vim.bo.filetype or '',
    first = first,
    last = last,
    lines = lines,
    diagnostics = config.include_diagnostics and diagnostics_between(first, last) or {},
  }

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
  local footer = footer_text(agents)

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
    pick_and_send(agents, build_payload(message, subject))
  end

  vim.keymap.set({ 'n', 'i' }, config.keys.send, submit, { buffer = buf, desc = 'Send to agent' })
  vim.keymap.set('n', config.keys.cancel, close, { buffer = buf, nowait = true, desc = 'Cancel' })
  vim.cmd('startinsert')
end

return M
