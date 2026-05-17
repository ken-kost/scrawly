defmodule Scrawly.Games.Word do
  use Ash.Resource,
    otp_app: :scrawly,
    domain: Scrawly.Games,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "words"
    repo Scrawly.Repo
  end

  actions do
    defaults [:read, :update, :destroy]

    create :create do
      accept [:text, :difficulty, :word_count]
      primary? true
    end

    read :list_all do
    end

    read :list_by_difficulty do
      argument :difficulty, :atom do
        allow_nil? false
        constraints one_of: [:easy, :medium, :hard]
      end

      filter expr(difficulty == ^arg(:difficulty))
    end

    read :list_by_difficulty_and_word_count do
      argument :difficulty, :atom do
        allow_nil? false
        constraints one_of: [:easy, :medium, :hard]
      end

      argument :word_count, :integer do
        allow_nil? false
        constraints min: 1, max: 3
      end

      filter expr(difficulty == ^arg(:difficulty) and word_count == ^arg(:word_count))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :difficulty, :atom do
      allow_nil? false
      default :medium
      public? true
      constraints one_of: [:easy, :medium, :hard]
    end

    attribute :word_count, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 3
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  # Seed data keyed by {word_count, difficulty}
  # 1-word: short concrete objects
  # 2-word: common two-word phrases
  # 3-word: three-word phrases / compound concepts
  @word_list %{
    # ── 1-word entries ──────────────────────────────────────────────────
    {1, :easy} => [
      "cat",
      "dog",
      "car",
      "sun",
      "moon",
      "star",
      "book",
      "pen",
      "bird",
      "fish",
      "cake",
      "hat",
      "shoe",
      "ice",
      "snow",
      "rain",
      "bee",
      "ant",
      "fire",
      "tea",
      "bus",
      "ring",
      "boat",
      "tree",
      "door",
      "milk",
      "drum",
      "hill",
      "cave",
      "coat"
    ],
    {1, :medium} => [
      "house",
      "apple",
      "chair",
      "table",
      "horse",
      "cloud",
      "candy",
      "shirt",
      "pants",
      "dress",
      "watch",
      "phone",
      "truck",
      "beach",
      "ocean",
      "river",
      "bread",
      "pizza",
      "juice",
      "water",
      "chess",
      "piano",
      "train",
      "island",
      "garden",
      "bridge",
      "flower",
      "window",
      "banana",
      "forest",
      "coffee",
      "valley",
      "meadow",
      "desert",
      "camera"
    ],
    {1, :hard} => [
      "mountain",
      "castle",
      "rainbow",
      "thunder",
      "lightning",
      "butterfly",
      "spider",
      "cheese",
      "glasses",
      "necklace",
      "guitar",
      "violin",
      "trumpet",
      "microphone",
      "computer",
      "television",
      "airplane",
      "bicycle",
      "motorcycle",
      "helicopter",
      "rocket",
      "submarine",
      "jungle",
      "volcano",
      "waterfall",
      "doctor",
      "teacher",
      "police",
      "firefighter",
      "chef",
      "artist",
      "musician",
      "dancer",
      "athlete",
      "scientist"
    ],

    # ── 2-word entries ──────────────────────────────────────────────────
    {2, :easy} => [
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
      "pin head"
    ],
    {2, :medium} => [
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
      "fish tank"
    ],
    {2, :hard} => [
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
      "lunar eclipse"
    ],

    # ── 3-word entries ──────────────────────────────────────────────────
    {3, :easy} => [
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
      "kit and kaboodle",
      "lock and key",
      "map and compass",
      "nut and bolt",
      "oil and water",
      "pen and paper",
      "red and blue",
      "sun and moon"
    ],
    {3, :medium} => [
      "jack in box",
      "fish and chips",
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
      "rock and roll",
      "song of birds",
      "tale of adventure"
    ],
    {3, :hard} => [
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
      "crown of thorns",
      "dance in rain",
      "eyes of tiger",
      "fork in road",
      "garden of eden",
      "hand of fate",
      "jack of trades",
      "keeper of keys",
      "lord of rings",
      "march of penguins",
      "needle in haystack",
      "out of this"
    ]
  }

  def word_list, do: @word_list

  def all_words_flat do
    @word_list
    |> Map.values()
    |> List.flatten()
  end

  def seed_words do
    Enum.each(@word_list, fn {{word_count, difficulty}, words} ->
      Enum.each(words, fn word_text ->
        case Ash.create(Scrawly.Games.Word, %{
               text: word_text,
               difficulty: difficulty,
               word_count: word_count
             }) do
          {:ok, _word} -> :ok
          {:error, _} -> :ok
        end
      end)
    end)
  end
end
