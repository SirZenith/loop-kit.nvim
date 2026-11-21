-- Lazy plugin entry point: registering the command never loads the board.
if vim.g.loaded_loop_kit == 1 then
  return
end
vim.g.loaded_loop_kit = 1

vim.api.nvim_create_user_command("LoopKit", function(cmd)
  require("loop-kit").command(cmd.args, cmd.fargs)
end, {
  nargs = "*",
  desc = "Open and manage the LOOP task board",
  complete = function(arglead)
    return require("loop-kit").complete(arglead)
  end,
})
