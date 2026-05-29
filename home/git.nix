{ ... }: {
  # home-manager 25.11 以降、programs.git は user/email/aliases/extraConfig を
  # 廃止して settings 一元管理へ移行 (release notes 参照)。
  # settings.<section>.<key> = value の attrset がそのまま .gitconfig になる。
  programs.git = {
    enable = true;

    # 旧 .gitignore_global
    ignores = [
      ".DS_Store"
      ".AppleDouble"
      ".LSOverride"
      ".idea"
    ];

    # 旧 [filter "lfs"] セクション。enable = true だけで filter 4行を自動生成。
    lfs.enable = true;

    settings = {
      user = {
        name = "wadakatu";
        email = "wadakatukoyo330@gmail.com";
      };

      alias = {
        st = "status";
        c = "commit";
        pushff = "push --force-with-lease --force-if-includes";
      };

      init.defaultBranch = "main";

      core = {
        editor = "vim";
        ignorecase = false;
        quotepath = false;
      };

      color.ui = "auto";
      push.default = "simple";
      credential.helper = "osxkeychain";
      pull.rebase = true;
    };
  };
}
