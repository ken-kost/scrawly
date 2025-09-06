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
      accept [:text]
      primary? true
    end

    read :get_random_word do
      # Simple random selection - will be implemented via domain function
    end

    read :list_all do
      # Get all words for validation/testing
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 20
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  # Seed data - 100 common words for drawing game
  @word_list [
    "cat",
    "dog",
    "house",
    "car",
    "tree",
    "sun",
    "moon",
    "star",
    "book",
    "pen",
    "apple",
    "banana",
    "chair",
    "table",
    "window",
    "door",
    "flower",
    "bird",
    "fish",
    "horse",
    "mountain",
    "ocean",
    "river",
    "forest",
    "castle",
    "bridge",
    "garden",
    "rainbow",
    "cloud",
    "fire",
    "ice",
    "snow",
    "rain",
    "wind",
    "thunder",
    "lightning",
    "butterfly",
    "spider",
    "ant",
    "bee",
    "cake",
    "pizza",
    "bread",
    "cheese",
    "milk",
    "water",
    "coffee",
    "tea",
    "juice",
    "candy",
    "hat",
    "shoe",
    "shirt",
    "pants",
    "dress",
    "coat",
    "glasses",
    "watch",
    "ring",
    "necklace",
    "guitar",
    "piano",
    "drum",
    "violin",
    "trumpet",
    "microphone",
    "camera",
    "phone",
    "computer",
    "television",
    "airplane",
    "train",
    "boat",
    "bicycle",
    "motorcycle",
    "truck",
    "bus",
    "helicopter",
    "rocket",
    "submarine",
    "beach",
    "desert",
    "jungle",
    "volcano",
    "island",
    "cave",
    "waterfall",
    "meadow",
    "valley",
    "hill",
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
  ]

  def word_list, do: @word_list

  def seed_words do
    Enum.each(@word_list, fn word_text ->
      case Ash.create(Scrawly.Games.Word, %{text: word_text}) do
        {:ok, _word} -> :ok
        # Word might already exist, ignore error
        {:error, _} -> :ok
      end
    end)
  end
end
