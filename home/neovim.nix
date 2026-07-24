{ ... }: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;

    # 現在の init.lua をそのまま Home Manager が生成する設定へ取り込む。
    initLua = builtins.readFile ./config/nvim/init.lua;
  };

  # lazy.nvim のプラグイン定義と lockfile も宣言管理する。
  xdg.configFile = {
    "nvim/lua/plugins/init.lua".source = ./config/nvim/lua/plugins/init.lua;
    "nvim/lazy-lock.json".source = ./config/nvim/lazy-lock.json;
  };
}
