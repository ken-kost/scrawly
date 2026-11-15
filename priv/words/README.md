# The drawing words

`words.csv` holds every word a drawer can be given: the header
`text,difficulty,theme`, then one entry per line. `Scrawly.Games.WordList`
compiles it in, and every deploy makes the `words` table match it
(`Scrawly.Games.sync_words/0`). Renaming an entry deletes the old row and
inserts a new one.

An entry is a single word ("lighthouse") or a phrase of two to four words
("polar bear", "walk the dog", "needle in a haystack"). A game can be played
with phrases only, so the phrases are a list in their own right.

After an edit, run `mix test test/scrawly/games/word_list_test.exs`. It checks
the text rules below, duplicates, themes and the size of each group.

## What makes a good entry

- Most teenagers and adults know the word.
- It can be sketched in under a minute with a mouse or a finger.
- One sketch tells it apart from its neighbours. Keep "tree", "flower" and
  "diamond"; leave out species and varieties (birch, tulip, sapphire). When two
  words share a sketch (cup and mug, juggle and juggler, wink and blink), keep
  the one players type first.
- It is easy to spell. No word whose difficulty is its spelling
  (chrysanthemum, archipelago, kaleidoscope).
- No brands, real people or franchise characters, and nothing offensive.
- It is written as normally spelled. Closed compounds are one word
  ("popcorn", "cowboy", "thunderstorm"), never split ("pop corn").
- Nouns are singular unless the thing is plural ("grapes", "scissors",
  "goosebumps"). Actions are the bare verb ("jump", not "jumping"). A sport
  is its usual name ("boxing", "skiing").
- A single word has at most 12 letters, unless it is common. The lint lists
  the exceptions.

Text: lowercase ASCII letters, spaces, hyphens and apostrophes, at most 30
characters. No accents: write "pinata", not "piñata". Guesses ignore case,
spaces, punctuation and accents (`Scrawly.Games.Guess.key/1`), so two entries
with the same key are not allowed. The hint shows spaces, hyphens and
apostrophes as they are, so players see how many words there are and how long
each one is.

## What makes a good phrase

The rules above apply, and also:

- It is an established name or expression that a dictionary, a shop or a sign
  would use: "fire truck", "corn on the cob", "tip of the iceberg". Not two
  words that merely fit together ("den lamp", "jackal howl").
- It pictures as one scene that friends would guess once they see the blanks.
  An idiom is fine when its literal picture is the joke ("couch potato",
  "elephant in the room"). No abstract idioms ("give and take"), and no
  titles of films, books, songs or shows.
- It is written naturally, with its articles, prepositions and possessives:
  "jack in the box", "needle in a haystack", "brush your teeth",
  "bird's nest". Never drop a word to make it shorter.
- It has 2 to 4 words and at most 30 characters. A hyphenated word counts as
  one ("four-leaf clover" has two).
- It is not a closed compound split in two. If the dictionary writes it as one
  word ("popcorn", "racetrack", "fishbowl"), it is a single word. Where both
  are common ("light bulb", "fire truck"), use the open form: guesses ignore
  the space either way.
- It is not a single word with extra letters around it: "build a snowman"
  next to "snowman" is fine, "pop corn" next to "popcorn" is a clash.
- It does not share its sketch with another phrase: "ride a horse" or
  "horse riding", not both.
- Words that are spelled differently in American and British English and have
  the same length ("tire"/"tyre", "theater"/"theatre") are left out, because
  the blanks can't tell the player which spelling to type. American spelling
  is used otherwise ("armor", "spilled"); the blanks show its length.
- Actions are phrases too: "walk the dog", "fly a kite", "pitch a tent". They
  take the `actions` theme.

## Difficulty: how hard it is to draw and guess, never how long it is

| Difficulty | The word                                               | Examples                       | Guess rate  |
|------------|--------------------------------------------------------|--------------------------------|-------------|
| `easy`     | has one obvious sketch and is guessed quickly          | cat, sun, car, pizza           | 55% or more |
| `medium`   | needs a few details or some context                    | lighthouse, dentist, sneeze    | 40-55%      |
| `hard`     | needs a scene, an action, or elimination between ideas | traffic, architect, sleepwalk  | 25-40%      |

No word should be guessed by fewer than 25% of players: drop it or replace it.
The single words aim at about 35% easy, 45% medium and 20% hard.

Phrases are rated with the same rubric, against other phrases. On the benchmark
they are guessed about ten points less often than single words (median 35%
against 45%), so the phrase bands are lower and an easy phrase must be iconic:

| Difficulty | Phrase guess rate |
|------------|-------------------|
| `easy`     | 45% or more       |
| `medium`   | 30-45%            |
| `hard`     | 20-30%            |

No phrase should be guessed by fewer than 20% of players. The phrases aim at
about 30% easy, 45% medium and 25% hard, with at least 60 of each.

The guess rate is the share of players who guess the word in a round. When the
list was rebuilt, each rating was checked against the rates skribbl.io players
measured for the words both games share
(https://github.com/skribbliohints/skribbliohints.github.io). That list was a
benchmark only: no word was taken from it. Once our own play data exists, it
replaces the benchmark.

## Themes

Every entry has exactly one theme. Pick the one a player who chose that theme
would expect to draw. Every theme has at least 15 phrases.

| Theme       | Holds                                                                     |
|-------------|---------------------------------------------------------------------------|
| `animals`   | animals, and parts and homes of animals (paw, beak, nest, beehive)        |
| `food`      | food, drinks and meals (breakfast, picnic)                                |
| `objects`   | things you hold or use: tools, clothes, furniture, instruments, shapes    |
| `nature`    | plants, landscapes, weather, sky and space, seasons                       |
| `places`    | buildings, rooms and places you go to                                     |
| `people`    | jobs, family, body parts, and feelings and states (sad, cold, tired)      |
| `actions`   | verbs you act out (jump, sneeze, whisper)                                 |
| `sports`    | sports, games and outdoor pastimes, and their gear and people             |
| `transport` | vehicles and travel (bridge, ticket, suitcase, airport)                   |
| `fantasy`   | myths, fairy tales, Halloween and science fiction: dragon, king, robot    |

Feelings and states have no theme of their own: they are `people`, because
they describe a person. `actions` holds only things a person does. Holiday
figures are `fantasy` ("santa claus", "easter bunny", "tooth fairy");
holiday things take the theme of what they are ("christmas tree" is `nature`,
"easter egg" is `food`).

## Sources

- Our own choices.
- Quick, Draw! categories: this list includes words and phrases from the
  Quick, Draw! dataset's category list by Google Creative Lab
  (https://github.com/googlecreativelab/quickdraw-dataset/blob/master/categories.txt),
  licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
  Changes: we kept the categories that meet the rules above, lowercased them,
  and gave each a difficulty and a theme.
