-- Run with:
--
--   nvim --headless -u NONE -l tests/path_spec.lua
--
-- Plain asserts and a non-zero exit, no framework: lua/herdr-prompt/path.lua
-- needs nothing but a path and an agent record, and it is the one part of the
-- plugin where a mistake leaves no trace — the message names a file that does not
-- exist and the agent is left to guess. Everything else needs a herdr session or
-- a window to say anything, and is not worth a test that only restates it.
--
-- The `$` cases are here because vim.fs.relpath() normalises with environment
-- expansion left on and turns `$HOME.lua` into a path to nothing. Reaching for it
-- again would reintroduce that, and these are what would notice.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)

local path = require('herdr-prompt.path')

local checks, failures = 0, 0
local function check(name, got, want)
  checks = checks + 1
  if vim.deep_equal(got, want) then
    return
  end
  failures = failures + 1
  io.write(('not ok  %s\n        got  %s\n        want %s\n'):format(name, vim.inspect(got), vim.inspect(want)))
end

-- Only the fields the module looks at; the rest of a herdr agent record is noise
-- here.
local function agent(fields)
  return fields
end

--- relpath_under: the string work, where vim.fs.relpath() went wrong -----------

check('a path below the base', path.relpath_under('/repo', '/repo/lua/init.lua'), 'lua/init.lua')
check('$ is part of a file name, not a variable', path.relpath_under('/repo', '/repo/routes/$HOME.lua'), 'routes/$HOME.lua')
check('$ in a directory name too', path.relpath_under('/repo', '/repo/lib/$USER/x.lua'), 'lib/$USER/x.lua')
check('a sibling only shares the prefix', path.relpath_under('/repo', '/repo-other/x.lua'), nil)
check('an unrelated tree', path.relpath_under('/repo', '/elsewhere/x.lua'), nil)
check('a trailing slash on the base', path.relpath_under('/repo/', '/repo/x.lua'), 'x.lua')
check('the same directory is not below itself', path.relpath_under('/repo', '/repo'), nil)
check('the root as the base', path.relpath_under('/', '/repo/x.lua'), 'repo/x.lua')
check('the root as both', path.relpath_under('/', '/'), nil)
check('a tilde inside the path stays put', path.relpath_under('/repo', '/repo/~/x.lua'), '~/x.lua')
check('dot components are resolved', path.relpath_under('/repo', '/repo/lua/../lua/init.lua'), 'lua/init.lua')

--- base_dir: which directory the agent answers from ---------------------------

check('cwd is what an agent resolves against', path.base_dir(agent({ cwd = '/a', foreground_cwd = '/b' })), '/a')
check('foreground_cwd only when there is no cwd', path.base_dir(agent({ foreground_cwd = '/b' })), '/b')
check('an empty cwd counts as none', path.base_dir(agent({ cwd = '', foreground_cwd = '/b' })), '/b')
check('neither', path.base_dir(agent({})), nil)

--- relative and outside: what reaches the payload ----------------------------

local repo = '/repo'
check('a file the agent holds', path.relative(agent({ cwd = repo }), '/repo/lua/init.lua'), 'lua/init.lua')
check(
  'an agent in a subdirectory names it from there',
  path.relative(agent({ cwd = '/repo/lua' }), '/repo/lua/herdr-prompt/init.lua'),
  'herdr-prompt/init.lua'
)
check('a file above the agent', path.relative(agent({ cwd = '/repo/lua' }), '/repo/README.md'), nil)
check('an agent working elsewhere', path.relative(agent({ cwd = '/elsewhere' }), '/repo/README.md'), nil)
check('an agent with no directory at all', path.relative(agent({}), '/repo/README.md'), nil)

-- nil is what build_payload keys off to fall back to the absolute path, and what
-- puts [outside cwd] on the row.
check('outside, so the payload names it absolutely', path.outside(agent({ cwd = '/elsewhere' }), '/repo/x.lua'), true)
check('not outside', path.outside(agent({ cwd = repo }), '/repo/x.lua'), false)
check('a buffer with no file is not outside anything', path.outside(agent({ cwd = repo }), nil), false)
check('and has no relative path either', path.relative(agent({ cwd = repo }), nil), nil)

--- against the filesystem: symlinks and a real `$` in a name -----------------

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/real/pkg', 'p')
vim.fn.writefile({ 'local x = 1' }, tmp .. '/real/pkg/init.lua')
vim.fn.writefile({ 'local x = 1' }, tmp .. '/real/pkg/$HOME.lua')
;(vim.uv or vim.loop).fs_symlink(tmp .. '/real', tmp .. '/link')

-- herdr may report the cwd a shell printed, which keeps the link in it, while the
-- buffer path arrives resolved. Both have to land in the same tree.
check(
  'a cwd reached through a symlink is the same tree',
  path.relative(agent({ cwd = tmp .. '/link/pkg' }), vim.fn.resolve(tmp .. '/link/pkg/init.lua')),
  'init.lua'
)
check(
  'and so is the other way round',
  path.relative(agent({ cwd = tmp .. '/real' }), vim.fn.resolve(tmp .. '/link/pkg/init.lua')),
  'pkg/init.lua'
)
-- vim.fn.resolve() leaves `$` alone; it is only the normalising that expanded it.
check(
  'a file that really is named $HOME.lua',
  path.relative(agent({ cwd = tmp .. '/real' }), vim.fn.resolve(tmp .. '/real/pkg/$HOME.lua')),
  'pkg/$HOME.lua'
)
vim.fn.delete(tmp, 'rf')

io.write(('%d checks, %d failed\n'):format(checks, failures))
if failures > 0 then
  os.exit(1)
end
