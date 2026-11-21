local M = {}

local this = debug.getinfo(1, "S").source:sub(2)
M.helpers_dir = vim.fs.dirname(vim.fs.normalize(this))
M.tests_dir = vim.fs.dirname(M.helpers_dir)
M.root = vim.fs.dirname(M.tests_dir)
M.fixtures_dir = M.tests_dir .. "/fixtures"

return M
