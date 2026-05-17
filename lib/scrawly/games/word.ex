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
      accept [:text, :difficulty]
      primary? true
    end

    read :get_random_word do
      argument :difficulty, :atom do
        allow_nil? true
        constraints one_of: [:easy, :medium, :hard]
      end
    end

    read :list_all do
      # Get all words for validation/testing
    end

    read :list_by_difficulty do
      argument :difficulty, :atom do
        allow_nil? false
        constraints one_of: [:easy, :medium, :hard]
      end

      filter expr(difficulty == ^arg(:difficulty))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 20
    end

    attribute :difficulty, :atom do
      allow_nil? false
      default :medium
      public? true
      constraints one_of: [:easy, :medium, :hard]
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  @easy_words [
    "cat",
    "dog",
    "sun",
    "moon",
    "star",
    "book",
    "pen",
    "apple",
    "banana",
    "chair",
    "table",
    "door",
    "bird",
    "fish",
    "cake",
    "pizza",
    "bread",
    "cheese",
    "milk",
    "water",
    "tea",
    "hat",
    "shoe",
    "shirt",
    "dress",
    "ring",
    "phone",
    "bus",
    "car",
    "tree",
    "flower",
    "cloud",
    "rain",
    "snow",
    "fire",
    "bee",
    "ant"
  ]

  @medium_words [
    "house",
    "car",
    "tree",
    "window",
    "horse",
    "ocean",
    "river",
    "forest",
    "castle",
    "bridge",
    "garden",
    "rainbow",
    "butterfly",
    "spider",
    "coffee",
    "juice",
    "candy",
    "pants",
    "coat",
    "glasses",
    "watch",
    "necklace",
    "guitar",
    "piano",
    "drum",
    "camera",
    "computer",
    "television",
    "airplane",
    "train",
    "boat",
    "bicycle",
    "motorcycle",
    "truck",
    "helicopter",
    "rocket",
    "beach",
    "desert",
    "jungle",
    "volcano",
    "island",
    "cave",
    "waterfall",
    "meadow",
    "valley",
    "hill"
  ]

  @hard_words [
    "mountain",
    "thunder",
    "lightning",
    "microphone",
    "violin",
    "trumpet",
    "submarine",
    "doctor",
    "teacher",
    "police",
    "firefighter",
    "chef",
    "artist",
    "musician",
    "dancer",
    "athlete",
    "scientist",
    "saxophone",
    "accordion",
    "trombone",
    "cellphone",
    "smartphone",
    "laptop",
    "notebook",
    "backpack",
    "umbrella",
    "snowboard",
    "skateboard",
    "telescope",
    "microscope",
    "stethoscope",
    "thermometer"
  ]

  def word_list, do: @easy_words ++ @medium_words ++ @hard_words

  def seed_words do
    Enum.each(@easy_words, &create_word(&1, :easy))
    Enum.each(@medium_words, &create_word(&1, :medium))
    Enum.each(@hard_words, &create_word(&1, :hard))
  end

  defp create_word(word_text, difficulty) do
    case Ash.create(Scrawly.Games.Word, %{text: word_text, difficulty: difficulty}) do
      {:ok, _word} -> :ok
      {:error, _} -> :ok
    end
  end
end
