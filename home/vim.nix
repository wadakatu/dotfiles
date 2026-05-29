{ ... }: {
  programs.vim = {
    enable = true;
    # extraConfig: .vimrc 末尾にそのまま追記される。
    # programs.vim.settings に型付き option もあるが、生の vim script を
    # 書ける extraConfig で旧 .vimrc をそのまま転記する方が確実。
    extraConfig = ''
      filetype plugin on
      syntax on

      set number
      set nowritebackup
      set nobackup
      set virtualedit=block
      set backspace=indent,eol,start

      set ignorecase
      set smartcase
      set wrapscan
      set incsearch
      set hlsearch
      set noerrorbells

      set smartindent
    '';
  };
}
