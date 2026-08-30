if vim.g.loaded_kangaroo == 1 then return end
vim.g.loaded_kangaroo = 1

local kangaroo = require("kangaroo")
kangaroo.setup()
