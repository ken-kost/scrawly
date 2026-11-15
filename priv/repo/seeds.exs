# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It makes the `words` table match priv/words/words.csv, the curated drawing
# words (every deploy does the same through bin/migrate). Running it again
# changes nothing.

%{inserted: inserted, updated: updated, deleted: deleted} = Scrawly.Games.sync_words()
IO.puts("words: #{inserted} inserted, #{updated} updated, #{deleted} deleted")
