-- Default highlight groups. No colorscheme is shipped: every group links to a
-- generic Neovim group and is declared with `default = true`, so a user or a
-- colorscheme can override it at any time.
local M = {}

M.links = {
  LoopKitPending = "Comment",
  LoopKitDoing = "Constant",
  LoopKitDone = "String",
  LoopKitBlocked = "WarningMsg",
  LoopKitId = "Identifier",
  LoopKitTitle = "Title",
  LoopKitTag = "Special",
  LoopKitMuted = "Comment",
  LoopKitHeader = "Label",
  LoopKitError = "ErrorMsg",
  LoopKitSelected = "Visual",
}

--- Define every default group. Safe to call more than once.
function M.setup()
  for name, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
