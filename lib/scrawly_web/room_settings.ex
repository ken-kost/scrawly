defmodule ScrawlyWeb.RoomSettings do
  @moduledoc """
  A room's settings as players see them: the fields of
  `ScrawlyWeb.Components.RoomSettingsForm`, their options and labels, and the
  one-line summary the room list and the lobby show. The wording lives here
  only, so every screen says the same thing.

  The form keeps every value as a string (what the DOM hands back) and sends
  them that way, keyed like `defaults/0`; `to_attrs/2` turns them into Room
  attributes on the server.

  Everything except `to_attrs/2` and `failure/2` also runs in the browser
  (templates and component actions).
  """

  alias Scrawly.Games.AnswerKind

  # The Room's own limits (Room attribute constraints; a test keeps them equal).
  @name_max 40
  @theme_max 200

  @defaults %{
    name: "",
    answer_kind: Atom.to_string(AnswerKind.default()),
    word_source: "local",
    prompt: "",
    ai_tone: "fun",
    round_duration: "60",
    round_multiplier: "1",
    max_players: "8"
  }

  @keys Map.keys(@defaults)

  @answer_options [{"words", "words"}, {"phrases", "phrases"}, {"mixed", "mixed"}]

  # One line of what each answer kind gives, from the curated list.
  @examples %{
    "words" => "frog · bicycle · castle",
    "phrases" => "polar bear · jack in the box · traffic light",
    "mixed" => "frog · polar bear · castle"
  }

  @topic_options [{"local", "everything"}, {"ai", "your own theme"}]
  @style_options [{"fun", "fun"}, {"creative", "creative"}, {"weird", "weird"}]
  @draw_time_options [{"60", "60 s"}, {"120", "2 min"}, {"300", "5 min"}]
  @turn_options [{"1", "1"}, {"2", "2"}, {"3", "3"}, {"5", "5"}]
  @player_options Enum.map(2..12, &{Integer.to_string(&1), "up to #{&1}"})

  @generic_failure "couldn't create the room, try again"

  # ── Form values ──────────────────────────────────────────────────────

  @doc "The values a new room starts from: every one of them is playable."
  @spec defaults() :: %{atom => String.t()}
  def defaults, do: @defaults

  @doc """
  The form's values: `initial` over `defaults/0`. `initial` may hold strings,
  atoms or integers (a room's own fields work as they are); other keys and
  `nil` values are ignored.
  """
  @spec form_values(term) :: %{atom => String.t()}
  def form_values(initial) when is_map(initial) do
    Enum.reduce(@keys, @defaults, fn key, values ->
      case form_string(Map.get(initial, key)) do
        nil -> values
        value -> Map.put(values, key, value)
      end
    end)
  end

  def form_values(_initial), do: @defaults

  defp form_string(value) when is_binary(value), do: value
  defp form_string(value) when is_integer(value), do: Integer.to_string(value)
  defp form_string(nil), do: nil
  defp form_string(value) when is_boolean(value), do: nil
  defp form_string(value) when is_atom(value), do: Atom.to_string(value)
  defp form_string(_value), do: nil

  @doc "Whether `key` is one of the form's fields."
  @spec field?(term) :: boolean
  def field?(key), do: key in @keys

  @doc """
  Whether the values ask for your own theme without one: the form can't be
  submitted then (and the server refuses it).
  """
  @spec missing_theme?(map) :: boolean
  def missing_theme?(values) do
    Map.get(values, :word_source) == "ai" and String.trim(Map.get(values, :prompt) || "") == ""
  end

  @doc "What an empty name becomes."
  @spec default_name(term) :: String.t()
  def default_name(username) when is_binary(username) and username != "",
    do: username <> "'s room"

  def default_name(_username), do: "new room"

  @doc "The longest name a room takes, in characters."
  @spec name_max() :: pos_integer
  def name_max, do: @name_max

  @doc "The longest theme a room takes, in characters."
  @spec theme_max() :: pos_integer
  def theme_max, do: @theme_max

  # ── Options (value, label) in the order the form shows them ─────────

  @doc false
  def answer_options, do: @answer_options
  @doc false
  def topic_options, do: @topic_options
  @doc false
  def style_options, do: @style_options
  @doc false
  def draw_time_options, do: @draw_time_options
  @doc false
  def turn_options, do: @turn_options
  @doc false
  def player_options, do: @player_options

  @doc "The example line under \"answers\" for a form value."
  @spec example(term) :: String.t()
  def example(answer_kind), do: Map.get(@examples, answer_kind, "frog · polar bear · castle")

  @doc "The hint under \"turns each\" for a form value."
  @spec turns_hint(term) :: String.t()
  def turns_hint("1"), do: "everyone draws once"
  def turns_hint("2"), do: "everyone draws twice"
  def turns_hint(turns) when is_binary(turns), do: "everyone draws " <> turns <> " times"
  def turns_hint(_turns), do: ""

  # ── Labels for a room's settings (atoms and integers, as rooms hold them) ──

  @doc "\"words\", \"phrases\" or \"mixed\"."
  @spec answers_label(term) :: String.t()
  def answers_label(kind) when kind in [:words, :phrases, :mixed], do: Atom.to_string(kind)
  def answers_label(_kind), do: "mixed"

  @doc "\"60 s\", \"2 min\", \"5 min\" (whole minutes from two on, else seconds)."
  @spec draw_time_label(term) :: String.t()
  def draw_time_label(seconds)
      when is_integer(seconds) and seconds >= 120 and rem(seconds, 60) == 0,
      do: Integer.to_string(div(seconds, 60)) <> " min"

  def draw_time_label(seconds) when is_integer(seconds), do: Integer.to_string(seconds) <> " s"
  def draw_time_label(_seconds), do: "60 s"

  @doc "\"1 turn each\", \"2 turns each\"."
  @spec turns_label(term) :: String.t()
  def turns_label(1), do: "1 turn each"
  def turns_label(turns) when is_integer(turns), do: Integer.to_string(turns) <> " turns each"
  def turns_label(_turns), do: "1 turn each"

  @doc "\"everything\" or \"your own theme\"."
  @spec topic_label(term) :: String.t()
  def topic_label(:ai), do: "your own theme"
  def topic_label(_word_source), do: "everything"

  @doc """
  What a room plays, in one line: "mixed · 60 s · 2 turns each". Missing
  fields read as the Room's defaults.
  """
  @spec summary(map) :: String.t()
  def summary(room) do
    answers_label(Map.get(room, :answer_kind)) <>
      " · " <>
      draw_time_label(Map.get(room, :round_duration)) <>
      " · " <> turns_label(Map.get(room, :round_multiplier))
  end

  @doc "The theme of a room that plays its own theme, else nil."
  @spec theme(map) :: String.t() | nil
  def theme(room) do
    prompt = Map.get(room, :prompt)
    if Map.get(room, :word_source) == :ai and is_binary(prompt) and prompt != "", do: prompt
  end

  # ── Server side ──────────────────────────────────────────────────────

  @ai_tones %{"fun" => :fun, "creative" => :creative, "weird" => :weird}

  @doc """
  Room attributes from form values (server-only).

  Total over any params map: forged values (`max_players: "abc"`, an unknown
  tone) become inputs the Room's constraints reject, never an exception. A
  missing or blank name becomes `default_name(username)`. Other missing
  (nil) values are left out, so the Room's defaults apply. A missing, forged
  or unknown answer kind is the default one, and a word source other than
  "ai" is the built-in list (whose rooms keep no theme or style).
  """
  @spec to_attrs(map, term) :: map
  def to_attrs(params, username) when is_map(params) do
    word_source = if Map.get(params, :word_source) in ["ai", :ai], do: :ai, else: :local

    %{
      name: name(Map.get(params, :name), username),
      max_players: parse_int(Map.get(params, :max_players)),
      answer_kind: AnswerKind.parse(Map.get(params, :answer_kind)),
      word_source: word_source,
      prompt: if(word_source == :ai, do: Map.get(params, :prompt)),
      round_duration: parse_int(Map.get(params, :round_duration)),
      round_multiplier: parse_int(Map.get(params, :round_multiplier)),
      ai_tone: if(word_source == :ai, do: ai_tone(Map.get(params, :ai_tone)))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp name(name, username) when is_binary(name) do
    if String.trim(name) == "", do: default_name(username), else: name
  end

  defp name(nil, username), do: default_name(username)
  defp name(name, _username), do: name

  # An unparsable value goes through as is, so the attribute's cast rejects it.
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp parse_int(value), do: value

  defp ai_tone(tone), do: Map.get(@ai_tones, tone, tone)

  @doc """
  Where and why a room was refused (server-only): `{field, message}` for the
  form, `field` one of `:name`, `:prompt`, `:max_players`, or `nil` for the
  line above its buttons. `attrs` are the attributes that were tried.
  """
  @spec failure(term, map) :: {atom | nil, String.t()}
  def failure(%Ash.Error.Invalid{errors: errors}, attrs) do
    fields = Enum.map(errors, &Map.get(&1, :field))

    cond do
      :name in fields ->
        {:name, "use a name of at most #{@name_max} characters"}

      :prompt in fields ->
        prompt = Map.get(attrs, :prompt)

        if is_binary(prompt) and String.trim(prompt) != "",
          do: {:prompt, "use a theme of at most #{@theme_max} characters"},
          else: {:prompt, "type a theme, or pick everything"}

      :max_players in fields ->
        {:max_players, "pick 2 to 12 players"}

      true ->
        {nil, @generic_failure}
    end
  end

  def failure(_error, _attrs), do: {nil, @generic_failure}
end
