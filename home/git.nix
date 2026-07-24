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
      "._*"
      ".idea"
      "**/.claude/settings.local.json"
      "**/CLAUDE.local.md"
    ];

    # 旧 [filter "lfs"] セクション。enable = true だけで filter 4行を自動生成。
    lfs.enable = true;

    # 現行 ~/.gitconfig を移植する。GitHub/Gist の credential.helper は
    # programs.gh が空文字との順序を含めて自動生成するため、ここでは重複定義しない。
    settings = {
      user = {
        name = "wadakatu";
        email = "72595463+wadakatu@users.noreply.github.com";
      };

      alias = {
        st = "status";
        c = "commit";
        clean-up = "!git fetch --prune && git branch -vv | grep 'gone]' | awk '{print $1}' | xargs git branch -D";
        pushff = "push --force-with-lease --force-if-includes";
      };

      column.ui = "auto";
      branch.sort = "-committerdate";
      tag.sort = "version:refname";
      init.defaultBranch = "main";

      diff = {
        algorithm = "histogram";
        colorMoved = "plain";
        mnemonicPrefix = true;
        renames = true;
      };

      fetch = {
        prune = true;
        all = true;
      };

      help.autocorrect = "prompt";

      rerere = {
        enabled = true;
        autoupdate = true;
      };

      rebase = {
        autoSquash = true;
        autoStash = true;
        updateRefs = true;
      };

      pull.rebase = true;
      merge.conflictStyle = "zdiff3";

      core = {
        editor = "nvim";
        ignorecase = false;
        quotepath = false;
      };

      color.ui = "auto";
      push.default = "simple";
    };
  };

  # 認証情報は Home Manager に書かず、初回に `gh auth login` で
  # macOS Keychain へ保存する。
  programs.gh = {
    enable = true;
    settings.aliases.co = "pr checkout";
  };
}
