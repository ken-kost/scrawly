# The drawing words

`words.csv` holds every word a drawer can be given: the header
`text,difficulty,theme`, then one entry per line. `Scrawly.Games.WordList`
compiles it in, and every deploy makes the `words` table match it
(`Scrawly.Games.sync_words/0`). Renaming an entry deletes the old row and
inserts a new one.

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
with the same key are not allowed.

## Difficulty: how hard it is to draw and guess, never how long it is

| Difficulty | The word                                               | Examples                       | Guess rate  |
|------------|--------------------------------------------------------|--------------------------------|-------------|
| `easy`     | has one obvious sketch and is guessed quickly          | cat, sun, car, pizza           | 55% or more |
| `medium`   | needs a few details or some context                    | lighthouse, dentist, sneeze    | 40-55%      |
| `hard`     | needs a scene, an action, or elimination between ideas | traffic, architect, sleepwalk  | 25-40%      |

No word should be guessed by fewer than 25% of players: drop it or replace it.
The single words aim at about 35% easy, 45% medium and 20% hard.

The guess rate is the share of players who guess the word in a round. When the
list was rebuilt, each rating was checked against the rates skribbl.io players
measured for the words both games share
(https://github.com/skribbliohints/skribbliohints.github.io). That list was a
benchmark only: no word was taken from it. Once our own play data exists, it
replaces the benchmark.

## Themes

Every single word has exactly one theme. Pick the one a player who chose that
theme would expect to draw.

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
they describe a person. `actions` holds only things a person does.

## Sources

- Our own choices.
- Quick, Draw! categories: this list includes words from the Quick, Draw!
  dataset's category list by Google Creative Lab
  (https://github.com/googlecreativelab/quickdraw-dataset/blob/master/categories.txt),
  licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
  Changes: we kept the categories that meet the rules above, lowercased them,
  and gave each a difficulty and a theme.
