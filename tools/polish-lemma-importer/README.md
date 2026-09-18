# Polish lemma pack builder

The builder converts the official SGJP text feed into the compact SQLite lookup
database bundled with the app. The database keeps each unique lowercase
`surface form → Wiktionary title` pair and discards grammatical rows that repeat
the same mapping.

```sh
curl -o /tmp/sgjp-20260823.tab.gz \
  https://download.sgjp.pl/morfeusz/20260823/sgjp-20260823.tab.gz
python3 tools/polish-lemma-importer/build.py \
  --input /tmp/sgjp-20260823.tab.gz \
  --output /tmp/PolishLemmas.sqlite3 \
  --compressed-output App/Resources/PolishMorphology/PolishLemmas.sqlite3.zlib
```

The source feed and the resulting inflectional mappings are distributed under
the 2-clause BSD license. Keep the bundled notice when updating the database.
