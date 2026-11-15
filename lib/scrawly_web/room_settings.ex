defmodule ScrawlyWeb.RoomSettings do
  @moduledoc """
  A room's settings as players see them: the fields of
  `ScrawlyWeb.Components.RoomSettingsForm`, their options and labels, and the
  one-line summary the room list and the lobby show. The wording lives here
  only, so every screen says the same thing.

  The form keeps every value as a string (what the DOM hands back) and sends
  them that way, keyed like `defaults/0`; `to_attrs/2` turns them into Room
  attributes on the server. The one exception is `themes`, the list of the
  theme chips that are on (their names, in `theme_options/0` order).

  "topic" is the `word_source` value: "local" (everything), "themes" (the
  built-in list, only the chosen `themes`) or "ai" (your own theme). A room
  stores the first two as `word_source: :local`, with `themes: []` meaning
  everything.

  The lobby's settings form changes a room with the same values, parsed and
  refused the same way (`to_attrs/2`, `failure/3`).

  Everything except `to_attrs/2` and `failure/3` also runs in the browser
  (templates and component actions).
  """

  alias Scrawly.Games.{AnswerKind, WordList}

  # The Room's own limits (Room attribute constraints; a test keeps them equal).
  @name_max 40
  @theme_max 200

  @defaults %{
    name: "",
    answer_kind: Atom.to_string(AnswerKind.default()),
    word_source: "local",
    themes: [],
    prompt: "",
    ai_tone: "fun",
    round_duration: "60",
    round_multiplier: "1",
    max_players: "8"
  }

  # The fields that hold a string (`themes` holds a list).
  @text_keys Map.keys(@defaults) -- [:themes]

  @answer_options [{"words", "words"}, {"phrases", "phrases"}, {"mixed", "mixed"}]

  # One line of what each answer kind gives, from the curated list.
  @examples %{
    "words" => "frog · bicycle · castle",
    "phrases" => "polar bear · jack in the box · traffic light",
    "mixed" => "frog · polar bear · castle"
  }

  @topic_options [{"local", "everything"}, {"themes", "themes"}, {"ai", "your own theme"}]

  # The theme chips, in WordList order (names, as the form holds them).
  @themes WordList.themes()
  @theme_names Enum.map(@themes, &Atom.to_string/1)
  # The room list and the lobby name at most this many themes, then "+N".
  @themes_shown 3
  @style_options [{"fun", "fun"}, {"creative", "creative"}, {"weird", "weird"}]
  @draw_time_options [{"60", "60 s"}, {"120", "2 min"}, {"300", "5 min"}]
  @turn_options [{"1", "1"}, {"2", "2"}, {"3", "3"}, {"5", "5"}]
  @player_options Enum.map(2..12, &{Integer.to_string(&1), "up to #{&1}"})
  @player_counts Map.new(2..12, &{Integer.to_string(&1), &1})

  @generic_failures %{
    create: "couldn't create the room, try again",
    update: "couldn't save the settings, try again"
  }

  # ── Form values ──────────────────────────────────────────────────────

  @doc "The values a new room starts from: every one of them is playable."
  @spec defaults() :: %{atom => String.t()}
  def defaults, do: @defaults

  @doc """
  The form's values: `initial` over `defaults/0`. `initial` may hold strings,
  atoms or integers (a room's own fields work as they are); other keys and
  `nil` values are ignored. `themes` may be theme atoms or names (unknown
  ones are dropped), and a room of the built-in list with themes opens on
  the "themes" topic.
  """
  @spec form_values(term) :: map
  def form_values(initial) when is_map(initial) do
    values =
      Enum.reduce(@text_keys, @defaults, fn key, values ->
        case form_string(Map.get(initial, key)) do
          nil -> values
          value -> Map.put(values, key, value)
        end
      end)

    themes = form_themes(Map.get(initial, :themes))
    values = %{values | themes: themes}

    if values.word_source == "local" and themes != [],
      do: %{values | word_source: "themes"},
      else: values
  end

  def form_values(_initial), do: @defaults

  defp form_string(value) when is_binary(value), do: value
  defp form_string(value) when is_integer(value), do: Integer.to_string(value)
  defp form_string(nil), do: nil
  defp form_string(value) when is_boolean(value), do: nil
  defp form_string(value) when is_atom(value), do: Atom.to_string(value)
  defp form_string(_value), do: nil

  # Theme names from atoms or names, known ones only, in chip order.
  defp form_themes(themes) when is_list(themes) do
    names = Enum.map(themes, &theme_name/1)
    for name <- @theme_names, name in names, do: name
  end

  defp form_themes(_themes), do: []

  defp theme_name(theme) when is_atom(theme), do: Atom.to_string(theme)
  defp theme_name(theme), do: theme

  @doc """
  Whether `key` is one of the form's text fields (every field but
  `themes`, which `toggle_theme/2` changes).
  """
  @spec field?(term) :: boolean
  def field?(key), do: key in @text_keys

  @doc """
  The theme chips that are on after the chip `name` was pressed: `name` on
  if it was off, off if it was on, in chip order. An unknown name changes
  nothing.
  """
  @spec toggle_theme(term, term) :: [String.t()]
  def toggle_theme(themes, name) do
    on = form_themes(themes)

    cond do
      name not in @theme_names -> on
      name in on -> for theme <- on, theme != name, do: theme
      true -> for theme <- @theme_names, theme == name or theme in on, do: theme
    end
  end

  @doc """
  Whether the values ask for your own theme without one: the form can't be
  submitted then (and the server refuses it).
  """
  @spec missing_theme?(map) :: boolean
  def missing_theme?(values) do
    Map.get(values, :word_source) == "ai" and String.trim(Map.get(values, :prompt) || "") == ""
  end

  @doc """
  Whether the values ask for themes with no chip on: the form can't be
  submitted then.
  """
  @spec missing_themes?(map) :: boolean
  def missing_themes?(values) do
    Map.get(values, :word_source) == "themes" and form_themes(Map.get(values, :themes)) == []
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
  def theme_options, do: @theme_names
  @doc false
  def style_options, do: @style_options
  @doc false
  def draw_time_options, do: @draw_time_options
  @doc false
  def turn_options, do: @turn_options
  @doc false
  def player_options, do: @player_options

  @doc """
  Whether the players option `value` ("2".."12") is below `min`, the
  players already in the room: the lobby's form can't offer it.
  """
  @spec too_few_players?(term, term) :: boolean
  def too_few_players?(value, min) when is_integer(min),
    do: Map.get(@player_counts, value, 0) < min

  def too_few_players?(_value, _min), do: false

  @doc """
  Why "players" can't go lower: "3 players are in the room, so pick 3 or
  more". The lobby's form says it under the field, and the server when it
  refuses a lower limit.
  """
  @spec players_floor(term) :: String.t()
  def players_floor(count) when is_integer(count),
    do:
      Integer.to_string(count) <>
        " players are in the room, so pick " <> Integer.to_string(count) <> " or more"

  def players_floor(_count), do: "pick 2 to 12 players"

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

  @doc """
  "everything", "themes" (a room of the built-in list with `themes`) or
  "your own theme".
  """
  @spec topic_label(term, term) :: String.t()
  def topic_label(word_source, themes \\ [])
  def topic_label(:ai, _themes), do: "your own theme"
  def topic_label(_word_source, [_ | _]), do: "themes"
  def topic_label(_word_source, _themes), do: "everything"

  @doc """
  A room's themes in a few words: "animals, food"; past three, the first
  three and how many more ("animals, food, objects +2"). `nil` for none
  (everything).
  """
  @spec themes_label(term) :: String.t() | nil
  def themes_label(themes) do
    case form_themes(themes) do
      [] ->
        nil

      names when length(names) > @themes_shown ->
        Enum.join(Enum.take(names, @themes_shown), ", ") <>
          " +" <> Integer.to_string(length(names) - @themes_shown)

      names ->
        Enum.join(names, ", ")
    end
  end

  @doc "Every one of a room's themes: \"animals, food, objects, nature\". `nil` for none."
  @spec themes_list(term) :: String.t() | nil
  def themes_list(themes) do
    case form_themes(themes) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

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

  `themes` is always set: the known themes among the values' `themes` for
  the "themes" topic (anything else in the list is dropped), `[]`
  (everything) for any other topic.
  """
  @spec to_attrs(map, term) :: map
  def to_attrs(params, username) when is_map(params) do
    word_source = if Map.get(params, :word_source) in ["ai", :ai], do: :ai, else: :local

    themes =
      if Map.get(params, :word_source) in ["themes", :themes],
        do: parse_themes(Map.get(params, :themes)),
        else: []

    %{
      name: name(Map.get(params, :name), username),
      max_players: parse_int(Map.get(params, :max_players)),
      answer_kind: AnswerKind.parse(Map.get(params, :answer_kind)),
      themes: themes,
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

  # The themes named in a list (atoms or names), in WordList order; anything
  # else in it, and anything that isn't a list, is dropped.
  defp parse_themes(themes) when is_list(themes) do
    given = MapSet.new(themes)

    for {theme, name} <- Enum.zip(@themes, @theme_names),
        MapSet.member?(given, theme) or MapSet.member?(given, name),
        do: theme
  end

  defp parse_themes(_themes), do: []

  @doc """
  Where and why a room, or a change to its settings (`:update`), was refused
  (server-only): `{field, message}` for the form, `field` one of `:name`,
  `:prompt`, `:max_players`, or `nil` for the line above its buttons.
  `attrs` are the attributes that were tried.
  """
  @spec failure(term, map, :create | :update) :: {atom | nil, String.t()}
  def failure(error, attrs, action \\ :create)

  def failure(%Ash.Error.Invalid{errors: errors}, attrs, action) do
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
        {nil, generic_failure(action)}
    end
  end

  def failure(_error, _attrs, action), do: {nil, generic_failure(action)}

  defp generic_failure(action), do: Map.get(@generic_failures, action, @generic_failures.create)
end
