# Core data

| File | What | Source and licence |
|---|---|---|
| `emoji.tsv` | Emoji shortcodes (`alias<TAB>emoji`, Unicode 15.0 and older, in Unicode order) for `:shortcode` suggestions | [gemoji](https://github.com/github/gemoji) `db/emoji.json`, MIT (`emoji-LICENSE.txt`) |

Regenerate `emoji.tsv` from a newer `emoji.json` with the snippet in `core/src/emoji.rs`.
