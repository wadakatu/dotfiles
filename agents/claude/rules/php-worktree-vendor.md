# PHP プロジェクトの linked worktree と vendor

- linked worktree で `vendor` を主 checkout への symlink にしない（`ln -s <主 checkout>/vendor vendor`）。
  PHP の `__DIR__` は symlink を解決した実パスを返すので、`vendor/composer/autoload_psr4.php` の
  `$baseDir = dirname($vendorDir)` が主 checkout を指す。PSR-4 のクラス（`App\` など）は主 checkout の `app/` から読まれ、
  テストは緑になるが worktree 側の変更は一切検証されない。
- worktree が主 checkout と同じコミットなら `cp -a <主 checkout>/vendor vendor` で実コピーする。
  違うなら worktree で `composer install` する（プラットフォーム拡張の要件で落ちるなら `--ignore-platform-req=<ext>` を足す）。
- テストの前に、ロード元が worktree になっていることを確かめる:
  `php -r 'require "vendor/autoload.php"; echo (new ReflectionClass(<アプリのクラス>))->getFileName();'`
  で worktree のパスが出ること。

**Why:** symlink のまま回したテストが緑になったのに、実際にロードされていたのは主 checkout のコードで、
worktree の変更は何も検証されていなかった（false-GREEN）。こうなると「テストが通った」という報告ごと信用できなくなる。
vendor は autoload の基準点になるので、コピーで済む生成物のディレクトリとは扱いが違う。
