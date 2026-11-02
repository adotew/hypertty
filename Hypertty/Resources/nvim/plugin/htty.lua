vim.api.nvim_create_user_command('HttyDiff', function(command) require('htty.diff').open(command.args) end, {
  nargs = '?',
  complete = 'file',
  desc = 'Changes since HEAD, in their own buffers',
})
