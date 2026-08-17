if vim.g.loaded_herdr_prompt then
  return
end
vim.g.loaded_herdr_prompt = true

vim.api.nvim_create_user_command('HerdrPrompt', function(args)
  -- What to attach is decided here, where the command still knows how it was
  -- called. Three cases, in order:
  --
  -- An explicit range is taken at its word: those lines, whole. It is also what a
  -- `:` mapping produces from visual mode, where the '<,'> range is all that
  -- survives the trip through the command line.
  --
  -- Reached through a <Cmd> mapping, visual mode is still live, and this is the
  -- one moment the selection can be read directly -- getpos('v') and the cursor --
  -- instead of through the '< and '> marks, which describe the *previous*
  -- selection until this one ends. The snapshot is taken now and visual mode left
  -- at once, so everything after runs from normal mode.
  --
  -- Anything else is a message with nothing attached, rather than one carrying
  -- whichever line the cursor happened to rest on as though that were the
  -- question.
  local opts = {}
  local mode = vim.fn.mode()
  if args.range > 0 then
    opts.line1, opts.line2 = args.line1, args.line2
  elseif mode:match('^[vV\22]') then
    opts.selection = { mode = mode, from = vim.fn.getpos('v'), to = vim.fn.getpos('.') }
    vim.cmd([[execute "normal! \<Esc>"]])
  end
  require('herdr-prompt').open(opts)
end, {
  desc = 'Ask a herdr agent about the current selection, or about nothing in particular',
  range = true,
})
