if vim.g.loaded_herdr_prompt then
  return
end
vim.g.loaded_herdr_prompt = true

vim.api.nvim_create_user_command('HerdrPrompt', function(args)
  require('herdr-prompt').open({ line1 = args.line1, line2 = args.line2 })
end, {
  desc = 'Ask a herdr agent about the current selection',
  range = true,
})
