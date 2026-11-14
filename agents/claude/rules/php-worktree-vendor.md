# PHP プロジェクトの linked worktree と vendor

- linked worktree の `vendor` を主 checkout への symlink にしない（`__DIR__` が実パスを返し、主 checkout のコードが読まれる）。
- 同じコミットなら `cp -a` で実コピー、違うなら worktree で `composer install`（拡張の要件で落ちるなら `--ignore-platform-req=<ext>`）。
- テスト前にロード元が worktree か確かめる: `php -r 'require "vendor/autoload.php"; echo (new ReflectionClass(<クラス>))->getFileName();'`

**Why:** symlink のままテストが緑になり、worktree の変更は未検証だった。
