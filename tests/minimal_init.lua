-- Minimal Neovim init for headless tests. No third-party runtime dependencies.
local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fs.dirname(vim.fs.normalize(this))
local root = vim.fs.dirname(tests_dir)

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.opt.confirm = false
vim.opt.shortmess:append("I")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  tests_dir .. "/?.lua",
  tests_dir .. "/?/init.lua",
  package.path,
}, ";")
