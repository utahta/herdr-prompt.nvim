if vim.g.loaded_herdr_prompt then
  return
end
vim.g.loaded_herdr_prompt = true

vim.api.nvim_create_user_command('HerdrPrompt', function(args)
  -- `range` counts the range parts the command was given: none from normal mode,
  -- two from a visual selection even where it covers a single line. The line
  -- numbers alone cannot tell those apart, since both arrive equal.
  --
  -- With no selection the lines are left out altogether and the message goes on
  -- its own, rather than carrying whichever line the cursor happened to rest on
  -- as though that were the question.
  local opts = {}
  if args.range > 0 then
    opts.line1, opts.line2 = args.line1, args.line2
  end
  require('herdr-prompt').open(opts)
end, {
  desc = 'Ask a herdr agent about the current selection, or about nothing in particular',
  range = true,
})
