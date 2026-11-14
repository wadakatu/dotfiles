# issue に着手する前に重複を探す

- 着手したら、コードを読む前に `gh issue list --search "<固有名> in:title,body" --state all` で同主旨の issue を探す。検索語は固有名にする。
- タイトルに語が無い issue もある。関連 tracking issue の子とコメント中の番号も開く（起票時も同じ）。
- 後発の issue が仕様として完成していれば、設計の出発点にする。
- 重複は PR 本文に `Closes #A` と並べる。どれを close するかは根拠を添えてユーザーに確かめる。
- CLOSED（stale bot の `NOT_PLANNED` も）を「却下済み」と書く前に、コメントが bot だけでないか見る。

**Why:** 使える仕様が後発の issue にあると、実装後に分かった。
