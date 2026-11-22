-- Default highlight groups. No colorscheme is shipped: every group links to a
-- generic Neovim group and is declared with `default = true`, so a user or a
-- colorscheme can override it at any time.
local M = {}

M.links = {
  LoopKitPending = "Comment",
  LoopKitDoing = "WarningMsg",
  LoopKitDone = "String",
  LoopKitBlocked = "Constant",
  LoopKitId = "Identifier",
  LoopKitTitle = "Title",
  LoopKitTag = "Special",
  LoopKitMuted = "Comment",
  LoopKitHeader = "Label",
  LoopKitError = "ErrorMsg",
  LoopKitSelected = "Special",
  LoopKitDetailTitle = "Title",
  LoopKitDetailSection = "Title",
  LoopKitDetailKey = "Comment",
  LoopKitDetailValue = "Normal",
  LoopKitDetailConstant = "Constant",
  LoopKitDetailPath = "String",
  LoopKitDetailMuted = "Comment",
  LoopKitDetailId = "Identifier",
  LoopKitDetailTag = "Special",
}

--- Define every default group. Safe to call more than once.
function M.setup()
  for name, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- Re-add the links if a colorscheme clears them after the board was loaded.
local augroup = vim.api.nvim_create_augroup("LoopKitHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = augroup,
  callback = function()
    M.setup()
  end,
  desc = "Re-apply loop-kit highlight links",
})

return M
