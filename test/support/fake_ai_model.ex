defmodule Scrawly.FakeAiModel do
  @moduledoc """
  Stands in for OpenAI in tests (`config :scrawly, Scrawly.Games.AiWords,
  model: Scrawly.FakeAiModel` in config/test.exs), so no test reaches the
  network.

  It answers like a model that ignores every rule of the prompt: whatever the
  answer kind, `reply/0` mixes words and phrases with duplicates, entries
  that are too long or too many words, punctuation, digits and things that
  aren't strings. A theme starting with "TEST fail" gets
  `{:error, :fake_model_down}`; one starting with "TEST raise" raises, like
  the real model without an API key.
  """

  @words ~w(octopus jellyfish starfish seahorse dolphin shark whale crab lobster
            seaweed anchor submarine coral shell pearl walrus penguin lighthouse
            sailboat mermaid sea-urchin)

  @phrases [
    "sea turtle",
    "message in a bottle",
    "sunken pirate ship",
    "killer whale",
    "fishing net",
    "deep sea diver",
    "sand dollar",
    "life jacket",
    "beach ball",
    "ocean wave",
    "coral reef",
    "tide pool"
  ]

  # What `Scrawly.Games.AiWords.filter/2` must keep (cleaned up) or drop.
  @messy [
    "  Clownfish ",
    "STINGRAY",
    "Treasure  Chest",
    "Bird’s Nest",
    "OCTOPUS",
    "Jelly-Fish",
    "Birds Nest",
    "fish & chips",
    "coral reef 2",
    "SpongeBob!",
    "the great big blue whale shark",
    "an extraordinarily enormous whale",
    "<script>",
    "---",
    "",
    "   ",
    42,
    nil
  ]

  def ask(%{arguments: %{prompt: "TEST fail" <> _}}, _context), do: {:error, :fake_model_down}
  def ask(%{arguments: %{prompt: "TEST raise" <> _}}, _context), do: raise("fake model crashed")
  def ask(_input, _context), do: {:ok, reply()}

  @doc "The reply, in the order the model sends it."
  def reply, do: @words ++ @messy ++ @phrases

  @doc "The single words `reply/0` holds once cleaned up, without duplicates."
  def clean_words, do: @words ++ ["clownfish", "stingray"]

  @doc "The phrases `reply/0` holds once cleaned up, without duplicates."
  def clean_phrases, do: ["treasure chest", "bird's nest"] ++ @phrases
end
