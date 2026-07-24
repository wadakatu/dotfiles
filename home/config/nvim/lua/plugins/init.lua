return {
  -- ===================
  -- Tokyo Night Theme (match Ghostty)
  -- ===================
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = true,
      terminal_colors = true,
      styles = {
        comments = { italic = true },
        keywords = { italic = true },
      },
    },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight-night")
    end,
  },

  -- ===================
  -- Status Line
  -- ===================
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        theme = "tokyonight",
        component_separators = { left = "", right = "" },
        section_separators = { left = "", right = "" },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch" },
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },

  -- ===================
  -- Syntax Highlighting
  -- ===================
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = function()
      -- Install parsers only on build (plugin install/update)
      require("nvim-treesitter").install({
        "lua",
        "php",
        "javascript",
        "typescript",
        "json",
        "yaml",
        "markdown",
        "bash",
      })
    end,
  },

  -- ===================
  -- Fuzzy Finder (for quick file/line jump)
  -- ===================
  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Find files" },
      { "<leader>fg", "<cmd>Telescope live_grep<CR>", desc = "Live grep" },
      { "<leader>fb", "<cmd>Telescope buffers<CR>", desc = "Buffers" },
      { "<leader>:", "<cmd>Telescope command_history<CR>", desc = "Command history" },
    },
    opts = {
      defaults = {
        layout_strategy = "horizontal",
        layout_config = { preview_width = 0.5 },
      },
    },
  },

  -- ===================
  -- Which Key (show keybindings)
  -- ===================
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      {
        "<leader>?",
        function()
          require("which-key").show({ global = false })
        end,
        desc = "Buffer Local Keymaps",
      },
    },
  },

  -- ===================
  -- Git Signs (show git changes in gutter)
  -- ===================
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
    },
  },
}
