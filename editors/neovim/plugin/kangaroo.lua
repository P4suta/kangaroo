if vim.g.loaded_kangaroo == 1 then return end
vim.g.loaded_kangaroo = 1

local kangaroo = require("kangaroo")
kangaroo.setup()

vim.api.nvim_create_autocmd("FileType", {
  pattern = "gleam",
  callback = function() kangaroo.start() end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() kangaroo.stop_all() end,
})
