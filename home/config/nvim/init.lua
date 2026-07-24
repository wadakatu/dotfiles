-- ===================
-- Leader Key (must be before lazy.nvim)
-- ===================
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- ===================
-- Basic Options
-- ===================
local opt = vim.opt

-- Line numbers
opt.number = true
opt.relativenumber = true

-- Indentation
opt.tabstop = 4
opt.shiftwidth = 4
opt.expandtab = true
opt.smartindent = true

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- Appearance
opt.termguicolors = true
opt.signcolumn = "yes"
opt.cursorline = true
opt.scrolloff = 8

-- Clipboard (system clipboard integration)
opt.clipboard = "unnamedplus"

-- Split behavior
opt.splitright = true
opt.splitbelow = true

-- Performance
opt.updatetime = 250
opt.timeoutlen = 300

-- Undo persistence
opt.undofile = true

-- ===================
-- Keymaps
-- ===================
local keymap = vim.keymap.set

-- Clear search highlight with Escape
keymap("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- Copy file#L123 to clipboard (GitHub style for Claude Code)
keymap("n", "<leader>yl", function()
  local location = vim.fn.expand("%:.") .. "#L" .. vim.fn.line(".")
  vim.fn.setreg("+", location)
  print("Copied: " .. location)
end, { desc = "Yank file#L123 to clipboard" })

-- Better window navigation (matches Ghostty I/J/K/L)
keymap("n", "<C-j>", "<C-w>h", { desc = "Move to left window" })
keymap("n", "<C-l>", "<C-w>l", { desc = "Move to right window" })
keymap("n", "<C-k>", "<C-w>j", { desc = "Move to lower window" })
keymap("n", "<C-i>", "<C-w>k", { desc = "Move to upper window" })

-- Jump to line quickly (type line number + Enter in normal mode)
keymap("n", "<CR>", function()
  local count = vim.v.count
  if count > 0 then
    vim.cmd("normal! " .. count .. "G")
  else
    -- Default Enter behavior
    vim.cmd("normal! j")
  end
end, { desc = "Jump to line or move down" })

-- Quick save
keymap("n", "<leader>w", "<cmd>w<CR>", { desc = "Save file" })

-- Quick quit
keymap("n", "<leader>q", "<cmd>q<CR>", { desc = "Quit" })

-- ===================
-- Bootstrap lazy.nvim
-- ===================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- ===================
-- Load Plugins
-- ===================
require("lazy").setup("plugins", {
  change_detection = {
    notify = false,
  },
})
