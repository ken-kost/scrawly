# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: running it again adds nothing that is already there.

# The curated drawing words (900: 300 each of 1-, 2- and 3-word entries).
# Without them rooms still get word choices (Scrawly.Games.get_random_word/1
# falls back to the built-in Scrawly.Games.Word list), but the table is where
# words can be added or curated.
Scrawly.SeedData.run()
