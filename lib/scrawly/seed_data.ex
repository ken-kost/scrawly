defmodule Scrawly.SeedData do
  @moduledoc """
  Seed 900 drawing words into the database (300 per word-count category).

  Run from a remote IEx shell:

      Scrawly.SeedData.run()       # seed all 900 words
      Scrawly.SeedData.reset()     # drop words, re-seed

  Or individually:

      Scrawly.SeedData.seed_one_word()
      Scrawly.SeedData.seed_two_word()
      Scrawly.SeedData.seed_three_word()
  """

  # ── 1-word entries (300 total: 100 easy, 100 medium, 100 hard) ────────

  @one_word_easy ~w(
    cat dog car sun moon star book pen bird fish
    cake hat shoe ice snow rain bee ant fire tea
    bus ring boat tree door milk drum hill cave coat
    box cup fan key map bed rug mop jar lid
    bat web pig cow hen fox owl elf gem rod
    log nut pit sap tub wig axe dam fig gum
    hut ivy jug keg lad mat nib oar pad rag
    sac tab urn vat wax yak zip ark bay cod
    den elm fur gap hoe inn jab koi lab mug
    nap oat paw rye sew tow use van wok yam
  )

  @one_word_medium ~w(
    house apple chair table horse cloud candy shirt pants dress
    watch phone truck beach ocean river bread pizza juice water
    chess piano train island garden bridge flower window banana forest
    coffee valley meadow desert camera crown globe torch medal arrow
    pearl badge stamp flame frost plume wheat cedar coral maple
    lemon grape peach mango olive melon prune guava acorn berry
    walnut cherry clover daisy poppy tulip orchid violet jasmine lotus
    cactus bamboo willow spruce birch aspen ember flint quartz slate
    marble granite copper silver bronze crystal sapphire ruby emerald amber
    shield anchor helmet saddle candle basket pillow blanket mirror carpet
  )

  @one_word_hard ~w(
    mountain castle rainbow thunder lightning butterfly spider cheese glasses necklace
    guitar violin trumpet microphone computer television airplane bicycle motorcycle helicopter
    rocket submarine jungle volcano waterfall doctor teacher police firefighter chef
    artist musician dancer athlete scientist astronaut architect engineer librarian surgeon
    chandelier telescope microscope typewriter accordion xylophone harmonica trombone saxophone clarinet
    caterpillar centipede crocodile chameleon porcupine hedgehog flamingo pelican penguin scorpion
    trampoline parachute binoculars wheelbarrow thermometer stethoscope metronome kaleidoscope periscope gyroscope
    labyrinth cathedral cathedral amphitheater colosseum aqueduct lighthouse windmill drawbridge barricade
    constellation hemisphere archipelago peninsula silhouette hologram silhouette prism spectrum silhouette
    gargoyle silhouette turquoise obsidian amethyst tourmaline chrysanthemum bougainvillea wisteria eucalyptus
  )

  # ── 2-word entries (300 total: 100 easy, 100 medium, 100 hard) ────────

  @two_word_easy [
    "hot dog",
    "ice cream",
    "rain drop",
    "sun hat",
    "tea cup",
    "bird nest",
    "gold fish",
    "bed bug",
    "pop corn",
    "lip stick",
    "eye ball",
    "arm chair",
    "cow boy",
    "sea star",
    "cup cake",
    "door bell",
    "snow man",
    "bat man",
    "egg cup",
    "fox hole",
    "pen pal",
    "sun burn",
    "bee hive",
    "car key",
    "dog bone",
    "ice cube",
    "jam jar",
    "mud pie",
    "nut shell",
    "pin head",
    "ant hill",
    "air bag",
    "cat nap",
    "ear ring",
    "fan belt",
    "gum drop",
    "hen house",
    "ink blot",
    "jig saw",
    "kit bag",
    "lap top",
    "mop head",
    "net ball",
    "oil can",
    "peg board",
    "rag doll",
    "sap wood",
    "tea bag",
    "toy box",
    "van pool",
    "wax seal",
    "yak milk",
    "zip tie",
    "ark door",
    "bay leaf",
    "cod fish",
    "den lamp",
    "elm bark",
    "fur coat",
    "gap fill",
    "hay bale",
    "inn room",
    "jet ski",
    "kid zone",
    "log fire",
    "map case",
    "nap time",
    "oat cake",
    "pad lock",
    "ram horn",
    "saw dust",
    "tin foil",
    "urn lid",
    "wok pan",
    "yam pie",
    "bug bite",
    "cap gun",
    "dew drop",
    "fig leaf",
    "gas lamp",
    "hop skip",
    "ivy vine",
    "jab step",
    "koi fish",
    "lab coat",
    "mug shot",
    "new moon",
    "old boot",
    "paw print",
    "red fox",
    "sky blue",
    "top hat",
    "web cam",
    "zap gun",
    "big toe",
    "dry run",
    "fly rod",
    "gym bag",
    "hoe cake",
    "jig step"
  ]

  @two_word_medium [
    "fire truck",
    "teddy bear",
    "palm tree",
    "high five",
    "blue whale",
    "roller skate",
    "candy cane",
    "alarm clock",
    "magic wand",
    "dream catcher",
    "jelly fish",
    "cotton candy",
    "french fries",
    "disco ball",
    "rubber duck",
    "treasure chest",
    "water slide",
    "picnic basket",
    "lava lamp",
    "space ship",
    "solar system",
    "polar bear",
    "diving board",
    "flower pot",
    "cheese burger",
    "paper plane",
    "music box",
    "paint brush",
    "night light",
    "beach ball",
    "swim suit",
    "bunk bed",
    "camp fire",
    "sand castle",
    "fish tank",
    "speed boat",
    "cloud nine",
    "gummy bear",
    "root beer",
    "dream boat",
    "chain link",
    "coral reef",
    "ghost town",
    "hedge maze",
    "ivory tower",
    "laser beam",
    "meteor shower",
    "ninja star",
    "orbit path",
    "pixel art",
    "quilt patch",
    "radar dish",
    "steam train",
    "trophy case",
    "ultra sound",
    "velvet rope",
    "wagon wheel",
    "crystal cave",
    "falcon wing",
    "harbor seal",
    "jackal howl",
    "kayak trip",
    "lemon drop",
    "marble arch",
    "nectar sip",
    "opal ring",
    "pumpkin seed",
    "quarry stone",
    "ribbon curl",
    "saddle horn",
    "tidal wave",
    "upper deck",
    "venom fang",
    "waffle iron",
    "zipper pull",
    "barrel roll",
    "cinder block",
    "dragon scale",
    "ember glow",
    "flint spark",
    "gravel path",
    "hollow log",
    "igloo dome",
    "jungle vine",
    "kettle drum",
    "lantern glow",
    "mossy rock",
    "nimbus cloud",
    "oyster bed",
    "plume smoke",
    "ripple pond",
    "shadow cast",
    "timber wolf",
    "valley fog",
    "winter storm",
    "bronze medal",
    "candle wick",
    "feather quill",
    "harbor light",
    "ivory tusk"
  ]

  @two_word_hard [
    "roller coaster",
    "haunted house",
    "northern lights",
    "bungee jumping",
    "crystal ball",
    "double rainbow",
    "electric guitar",
    "figure skating",
    "ginger bread",
    "horse riding",
    "ironing board",
    "karate chop",
    "lightning bolt",
    "mountain bike",
    "opera singer",
    "parallel bars",
    "quarter back",
    "rocking chair",
    "scuba diving",
    "thunder storm",
    "unicorn horn",
    "vacuum cleaner",
    "washing machine",
    "yoga mat",
    "zebra crossing",
    "bowling alley",
    "cactus plant",
    "dragon fly",
    "easter egg",
    "fishing rod",
    "garage door",
    "hamster wheel",
    "jigsaw puzzle",
    "kite surfing",
    "lunar eclipse",
    "anvil strike",
    "bamboo forest",
    "chimney sweep",
    "diamond mine",
    "engine block",
    "ferris wheel",
    "gravity pull",
    "harvest moon",
    "jackhammer noise",
    "kelp forest",
    "magnet field",
    "neutron star",
    "oxygen mask",
    "platinum ring",
    "quantum leap",
    "rhino charge",
    "serpent coil",
    "turbo engine",
    "uranium rod",
    "vortex spin",
    "wrecking ball",
    "python squeeze",
    "anchor chain",
    "basilisk gaze",
    "compass needle",
    "domino effect",
    "eclipse shadow",
    "furnace blast",
    "glacier melt",
    "horizon line",
    "inkwell spill",
    "javelin throw",
    "kinetic energy",
    "labyrinth path",
    "minotaur maze",
    "nebula glow",
    "obsidian blade",
    "pendulum swing",
    "quasar light",
    "resonance hum",
    "stalactite drip",
    "tessellation tile",
    "undertow pull",
    "ventricle pump",
    "wavelength shift",
    "xenon flash",
    "yearbook photo",
    "zeppelin flight",
    "aurora shimmer",
    "blizzard whirl",
    "catapult launch",
    "dirigible float",
    "equinox dawn",
    "fjord passage",
    "gargoyle perch",
    "helium balloon",
    "isthmus bridge",
    "juggernaut roll",
    "kaleidoscope turn",
    "longitude mark",
    "monolith shadow",
    "nocturne melody",
    "obelisk point",
    "pinnacle reach",
    "quicksilver flow"
  ]

  # ── 3-word entries (300 total: 100 easy, 100 medium, 100 hard) ────────

  @three_word_easy [
    "ice cream cone",
    "cup of tea",
    "bag of chips",
    "ball of yarn",
    "box of crayons",
    "can of beans",
    "ear of corn",
    "jar of honey",
    "jug of milk",
    "pot of gold",
    "ray of sun",
    "sea of clouds",
    "bed of roses",
    "bar of soap",
    "bow and arrow",
    "cat and dog",
    "day and night",
    "egg and spoon",
    "fun and games",
    "ham and cheese",
    "ink and pen",
    "jam and bread",
    "lock and key",
    "map and compass",
    "nut and bolt",
    "oil and water",
    "pen and paper",
    "red and blue",
    "sun and moon",
    "cup and plate",
    "bat and ball",
    "hat and scarf",
    "dot and line",
    "fork and knife",
    "salt and pepper",
    "pins and needles",
    "hide and seek",
    "hit and run",
    "mix and match",
    "now and then",
    "rise and shine",
    "safe and sound",
    "stop and go",
    "touch and feel",
    "ups and downs",
    "bits and bobs",
    "fish and chips",
    "push and pull",
    "rock and roll",
    "left and right",
    "black and white",
    "bread and butter",
    "cream and sugar",
    "drum and fife",
    "east and west",
    "fruit and veg",
    "give and take",
    "heart and soul",
    "ice and fire",
    "jump and skip",
    "kick and punt",
    "love and hate",
    "milk and honey",
    "near and far",
    "old and new",
    "peach and cream",
    "quick and slow",
    "rain and shine",
    "silk and satin",
    "thick and thin",
    "up and down",
    "vine and twig",
    "warm and cold",
    "yes and no",
    "zig and zag",
    "arm and leg",
    "bell and whistle",
    "cap and gown",
    "do and die",
    "eye and ear",
    "frog and toad",
    "goose and duck",
    "hop and jump",
    "in and out",
    "joy and peace",
    "kite and string",
    "lime and lemon",
    "meat and bone",
    "nod and wink",
    "owl and crow",
    "plum and pear",
    "quiz and test",
    "rod and reel",
    "ship and sail",
    "top and bottom",
    "use and care",
    "vest and tie",
    "web and thread",
    "yell and shout",
    "zoom and dash"
  ]

  @three_word_medium [
    "jack in box",
    "peanut butter jar",
    "bird of paradise",
    "ring of fire",
    "ace of spades",
    "tower of blocks",
    "coat of arms",
    "field of flowers",
    "game of chess",
    "house of cards",
    "island of treasure",
    "knight in armor",
    "land of dreams",
    "man on moon",
    "nest of eggs",
    "order of phoenix",
    "piece of cake",
    "queen of hearts",
    "rules of game",
    "school of fish",
    "trail of breadcrumbs",
    "umbrella in rain",
    "valley of kings",
    "wind and rain",
    "king of jungle",
    "lady and tramp",
    "master of disguise",
    "night of stars",
    "ocean of dreams",
    "pirates and treasure",
    "quest for gold",
    "song of birds",
    "tale of adventure",
    "voice of reason",
    "world of wonder",
    "book of spells",
    "clash of titans",
    "den of thieves",
    "edge of cliff",
    "feast of kings",
    "gate of heaven",
    "hall of fame",
    "isle of man",
    "jaws of life",
    "kiss of death",
    "lake of fire",
    "maze of mirrors",
    "net of stars",
    "oath of honor",
    "path of glory",
    "rain of petals",
    "scroll of wisdom",
    "throne of bones",
    "vault of gold",
    "wall of sound",
    "arch of stone",
    "blade of grass",
    "crown of thorns",
    "deck of cards",
    "eye of storm",
    "fork in road",
    "grain of sand",
    "herd of cattle",
    "jewel of nile",
    "knot of rope",
    "leap of faith",
    "mouth of cave",
    "nerve of steel",
    "orb of light",
    "pair of dice",
    "raft of logs",
    "sack of flour",
    "tomb of pharaoh",
    "unit of measure",
    "veil of mist",
    "wave of sound",
    "yard of fabric",
    "zone of silence",
    "band of brothers",
    "crest of wave",
    "dance of shadows",
    "flame of passion",
    "grove of oaks",
    "helm of ship",
    "ink of squid",
    "jade of east",
    "key of life",
    "loom of fate",
    "mask of zorro",
    "nook of garden",
    "orchard of apples",
    "plank of wood",
    "realm of dreams",
    "shores of time",
    "tower of babel",
    "bell of church",
    "cape of hero",
    "dust of stars",
    "flag of truce",
    "gift of gab"
  ]

  @three_word_hard [
    "bottom of ocean",
    "castle in sky",
    "dawn of time",
    "end of rainbow",
    "flight of stairs",
    "ghost of christmas",
    "heart of gold",
    "island of misfit",
    "journey through space",
    "kingdom of animals",
    "legend of dragon",
    "mystery of deep",
    "north star light",
    "once upon time",
    "portrait of artist",
    "quest for fire",
    "river of stars",
    "secrets of forest",
    "tip of iceberg",
    "under the sea",
    "voyage of discovery",
    "wheel of fortune",
    "bridge over river",
    "dance in rain",
    "eyes of tiger",
    "garden of eden",
    "hand of fate",
    "jack of trades",
    "keeper of keys",
    "lord of rings",
    "march of penguins",
    "needle in haystack",
    "out of bounds",
    "point of return",
    "riddle of sphinx",
    "sword in stone",
    "tree of life",
    "urn of ashes",
    "vow of silence",
    "wings of freedom",
    "apex of mountain",
    "blood of dragon",
    "crypt of kings",
    "depth of despair",
    "echo of thunder",
    "forge of giants",
    "glow of embers",
    "howl of wolf",
    "ire of gods",
    "jest of fool",
    "knell of doom",
    "lair of beast",
    "might of storm",
    "nexus of worlds",
    "oath of blood",
    "pyre of fallen",
    "quake of earth",
    "rage of titans",
    "siege of castle",
    "trial by fire",
    "vale of shadows",
    "wrath of nature",
    "yoke of burden",
    "zenith of power",
    "abyss of time",
    "bane of existence",
    "cradle of life",
    "dirge of souls",
    "elixir of youth",
    "fury of ocean",
    "gate of eternity",
    "helm of darkness",
    "idol of stone",
    "jewel of cosmos",
    "karma of past",
    "lore of ancients",
    "myth of creation",
    "nimbus of glory",
    "oracle of truth",
    "prism of light",
    "quest of champions",
    "rune of binding",
    "shroud of mystery",
    "temple of doom",
    "umbra of eclipse",
    "void of nothing",
    "ward of protection",
    "xyst of columns",
    "yield of harvest",
    "zeal of warrior",
    "arc of destiny",
    "brink of chaos",
    "cipher of ages",
    "dusk of empires",
    "enigma of stars",
    "fable of heroes",
    "gauntlet of trials",
    "hymn of peace",
    "isle of solitude",
    "judge of souls"
  ]

  @doc "Seed all 900 words (300 per word-count category)."
  def run do
    IO.puts("=== Seeding 1-word entries (300) ===")
    seed_one_word()

    IO.puts("=== Seeding 2-word entries (300) ===")
    seed_two_word()

    IO.puts("=== Seeding 3-word entries (300) ===")
    seed_three_word()

    count = Scrawly.Games.get_word_count()
    IO.puts("\n=== Done — #{count} words in database ===")
    :ok
  end

  @doc "Seed 300 one-word entries (100 easy, 100 medium, 100 hard)."
  def seed_one_word do
    seed_batch(@one_word_easy, 1, :easy)
    seed_batch(@one_word_medium, 1, :medium)
    seed_batch(@one_word_hard, 1, :hard)
  end

  @doc "Seed 300 two-word entries (100 easy, 100 medium, 100 hard)."
  def seed_two_word do
    seed_batch(@two_word_easy, 2, :easy)
    seed_batch(@two_word_medium, 2, :medium)
    seed_batch(@two_word_hard, 2, :hard)
  end

  @doc "Seed 300 three-word entries (100 easy, 100 medium, 100 hard)."
  def seed_three_word do
    seed_batch(@three_word_easy, 3, :easy)
    seed_batch(@three_word_medium, 3, :medium)
    seed_batch(@three_word_hard, 3, :hard)
  end

  @doc """
  Drop all words and re-seed. Use from a remote IEx shell:

      Scrawly.SeedData.reset()
  """
  def reset do
    IO.puts("Deleting all existing words...")

    case Scrawly.Games.get_all_words() do
      {:ok, words} ->
        Enum.each(words, fn word ->
          Ash.destroy!(word)
        end)

        IO.puts("Deleted #{length(words)} words.")

      {:error, reason} ->
        IO.puts("Warning: could not fetch words — #{inspect(reason)}")
    end

    run()
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp seed_batch(words, word_count, difficulty) do
    created =
      Enum.reduce(words, 0, fn text, acc ->
        case Ash.create(Scrawly.Games.Word, %{
               text: text,
               difficulty: difficulty,
               word_count: word_count
             }) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    IO.puts("  #{difficulty} (#{word_count}-word): #{created}/#{length(words)} created")
  end
end
