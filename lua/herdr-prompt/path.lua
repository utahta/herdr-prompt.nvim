-- How a file is named for a given agent.
--
-- Kept apart from the rest of the plugin because none of it depends on the
-- configuration, the herdr CLI or a window: it is a pure function of a path and
-- an agent record. It is also where a mistake is quietest — the agent is handed a
-- reference to a file that does not exist and nothing says so — which is why
-- tests/path_spec.lua exercises it directly.

local M = {}

-- Stands in for vim.fs.relpath(), which normalises with environment expansion
-- left on: a file honestly named `$HOME.lua` comes back as `Users/you.lua`, a
-- path that does not exist, and the agent would be handed a reference to
-- nothing. Both sides are normalised with that expansion off instead.
--
-- Comparing against `base .. '/'` is what keeps a sibling out: /repo-other is not
-- under /repo even though it shares the prefix. It also answers the case where
-- the two are the same directory, which a directory opened as a buffer can reach:
-- the tail comes out empty and nil sends the absolute path, since '.' would not
-- be a file reference.
function M.relpath_under(base, target)
  base = vim.fs.normalize(base, { expand_env = false })
  target = vim.fs.normalize(target, { expand_env = false })

  local prefix = base:sub(-1) == '/' and base or base .. '/'
  if target:sub(1, #prefix) ~= prefix then
    return nil
  end

  local rel = target:sub(#prefix + 1)
  return rel ~= '' and rel or nil
end

-- The directory an agent resolves relative paths against. foreground_cwd follows
-- whichever process currently holds the pane's terminal, so it moves as the agent
-- runs commands; it is only here for a pane that reports no cwd of its own.
--
-- Spelled out rather than looped over a list of the two, because a list built
-- from a missing cwd has a hole in it and ipairs would stop before reaching the
-- fallback.
function M.base_dir(agent)
  local dir = agent.cwd
  if type(dir) ~= 'string' or dir == '' then
    dir = agent.foreground_cwd
  end
  if type(dir) ~= 'string' or dir == '' then
    return nil
  end
  return dir
end

-- `target` as this agent can name it, or nil when it lies outside the agent's
-- directory. It is expected already resolved, and nil stands for a buffer with no
-- file at all.
--
-- Both sides end up resolved: herdr passes on the cwd a shell reported, which
-- keeps symlinks, and comparing that unevenly against a resolved file path would
-- miss a match. What comes back is the single fact behind both the absolute-path
-- fallback and the [outside cwd] marker, so the two cannot disagree.
function M.relative(agent, target)
  local base = M.base_dir(agent)
  if not base or not target then
    return nil
  end
  return M.relpath_under(vim.fn.resolve(base), target)
end

-- Whether a message to this agent will have to name the file absolutely. A buffer
-- with no file at all has no path either way, so it is not "outside" anything: it
-- neither carries the marker nor forces the picker.
function M.outside(agent, target)
  return target ~= nil and M.relative(agent, target) == nil
end

return M
