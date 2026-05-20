defmodule ScrawlyWeb.Components.AvatarDefs do
  @moduledoc """
  Holds the SVG `<defs>` with all preset-avatar `<symbol>` shapes.
  Render once near the top of the document; consumers reference them
  via `<use href="#a-..."/>` inside their own `<svg>` elements.
  """
  use Hologram.Component

  @avatars [
    {"a-apple", "Apple"},
    {"a-pear", "Pear"},
    {"a-cherry", "Cherry"},
    {"a-banana", "Banana"},
    {"a-melon", "Melon"},
    {"a-lemon", "Lemon"},
    {"a-avocado", "Avocado"},
    {"a-mushroom", "Mushroom"},
    {"a-cactus", "Cactus"},
    {"a-flower", "Flower"},
    {"a-leaf", "Leaf"},
    {"a-tree", "Tree"},
    {"a-sun", "Sun"},
    {"a-moon", "Moon"},
    {"a-star", "Star"},
    {"a-cloud", "Cloud"},
    {"a-rainbow", "Rainbow"},
    {"a-bolt", "Bolt"},
    {"a-umbrella", "Umbrella"},
    {"a-balloon", "Balloon"},
    {"a-kite", "Kite"},
    {"a-hotair", "Hot Air"},
    {"a-rocket", "Rocket"},
    {"a-boat", "Sailboat"},
    {"a-cupcake", "Cupcake"},
    {"a-donut", "Donut"},
    {"a-icecream", "Ice Cream"},
    {"a-coffee", "Coffee"},
    {"a-pizza", "Pizza"},
    {"a-fish", "Fish"}
  ]

  def avatars, do: @avatars

  def default_id, do: "a-mushroom"
  def default_color, do: "3"

  def name_for(id) do
    case Enum.find(@avatars, fn {a_id, _} -> a_id == id end) do
      {_, name} -> name
      _ -> "Mushroom"
    end
  end

  def template do
    ~HOLO"""
    <svg width="0" height="0" style="position: absolute" aria-hidden="true">
      <defs>
        <symbol id="a-apple" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 32 C30 28 22 48 28 68 C32 80 44 84 50 80 C56 84 68 80 72 68 C78 48 70 28 50 32 Z" />
          <path class="avatar-ink" d="M50 32 C50 22 56 16 64 16" />
          <path class="avatar-ink" d="M55 26 C60 22 67 22 72 26" />
        </symbol>
        <symbol id="a-pear" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 24 C44 24 42 32 44 38 C36 44 30 56 34 70 C38 84 62 84 66 70 C70 56 64 44 56 38 C58 32 56 24 50 24 Z" />
          <path class="avatar-ink" d="M50 24 L50 16" />
          <path class="avatar-ink" d="M50 18 C56 14 64 16 68 22" />
        </symbol>
        <symbol id="a-cherry" viewBox="0 0 100 100">
          <circle class="avatar-ink" cx="36" cy="70" r="14" />
          <circle class="avatar-ink" cx="66" cy="74" r="12" />
          <path class="avatar-ink" d="M36 56 C36 40 44 28 60 22" />
          <path class="avatar-ink" d="M66 62 C68 42 60 30 60 22" />
          <path class="avatar-ink" d="M52 22 C58 16 66 18 70 22" />
          <circle class="avatar-ink-fill" cx="32" cy="66" r="2" />
          <circle class="avatar-ink-fill" cx="62" cy="70" r="2" />
        </symbol>
        <symbol id="a-banana" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M22 38 C24 60 40 78 64 78 C76 78 84 72 84 64 C84 60 80 58 76 60 C70 64 56 62 46 52 C36 42 36 32 38 26 C40 22 36 18 32 22 C26 26 22 30 22 38 Z" />
          <path class="avatar-ink" d="M36 24 L34 18" />
        </symbol>
        <symbol id="a-melon" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M14 36 C30 22 70 22 86 36 L74 80 C58 90 42 90 26 80 L14 36 Z" />
          <path class="avatar-ink" d="M22 42 C36 32 64 32 78 42" />
          <circle class="avatar-ink-fill" cx="38" cy="58" r="2.5" />
          <circle class="avatar-ink-fill" cx="50" cy="64" r="2.5" />
          <circle class="avatar-ink-fill" cx="62" cy="58" r="2.5" />
          <circle class="avatar-ink-fill" cx="46" cy="72" r="2.5" />
          <circle class="avatar-ink-fill" cx="58" cy="72" r="2.5" />
        </symbol>
        <symbol id="a-lemon" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M18 50 C18 30 38 18 58 22 C70 24 80 30 82 42 C84 56 76 76 56 80 C36 84 18 70 18 50 Z" />
          <path class="avatar-ink" d="M22 36 L14 28" />
          <path class="avatar-ink" d="M82 64 L90 72" />
          <path class="avatar-ink" d="M40 38 C44 36 48 36 52 38" />
        </symbol>
        <symbol id="a-avocado" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 18 C32 18 24 38 24 56 C24 72 36 86 50 86 C64 86 76 72 76 56 C76 38 68 18 50 18 Z" />
          <ellipse class="avatar-ink" cx="50" cy="60" rx="14" ry="16" />
          <path class="avatar-ink" d="M50 18 L50 14" />
        </symbol>
        <symbol id="a-mushroom" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M18 50 C18 30 32 18 50 18 C68 18 82 30 82 50 L18 50 Z" />
          <path class="avatar-ink" d="M34 64 C34 56 38 50 38 50 L62 50 C62 50 66 56 66 64 C66 78 58 86 50 86 C42 86 34 78 34 64 Z" />
          <circle class="avatar-ink-fill" cx="38" cy="34" r="4" />
          <circle class="avatar-ink-fill" cx="58" cy="32" r="5" />
          <circle class="avatar-ink-fill" cx="68" cy="42" r="3" />
        </symbol>
        <symbol id="a-cactus" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M40 84 L40 56 C40 46 32 42 28 42 C24 42 22 46 22 50 L22 60" />
          <path class="avatar-ink" d="M60 84 L60 38 C60 28 68 24 72 24 C76 24 78 28 78 32 L78 50" />
          <path class="avatar-ink" d="M40 20 C40 14 44 12 50 12 C56 12 60 14 60 20 L60 84 Z" />
          <path class="avatar-ink" d="M40 84 L60 84" />
          <path class="avatar-ink" d="M48 36 L48 44 M52 56 L52 64" />
        </symbol>
        <symbol id="a-flower" viewBox="0 0 100 100">
          <circle class="avatar-ink" cx="50" cy="44" r="10" />
          <path class="avatar-ink" d="M50 14 C44 22 44 32 50 34" />
          <path class="avatar-ink" d="M50 14 C56 22 56 32 50 34" />
          <path class="avatar-ink" d="M76 24 C68 28 62 36 54 40" />
          <path class="avatar-ink" d="M86 50 C78 50 68 50 60 44" />
          <path class="avatar-ink" d="M76 76 C70 70 62 60 56 52" />
          <path class="avatar-ink" d="M50 88 L50 54" />
          <path class="avatar-ink" d="M24 76 C30 70 38 60 44 52" />
          <path class="avatar-ink" d="M14 50 C22 50 32 50 40 44" />
          <path class="avatar-ink" d="M24 24 C30 30 38 38 46 40" />
        </symbol>
        <symbol id="a-leaf" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M22 78 C20 50 38 22 82 18 C78 62 50 80 22 78 Z" />
          <path class="avatar-ink" d="M22 78 L70 30" />
          <path class="avatar-ink" d="M40 60 L52 56 M52 50 L62 42 M36 70 L46 66" />
        </symbol>
        <symbol id="a-tree" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 18 L22 50 L34 50 L18 70 L36 70 L26 84 L74 84 L64 70 L82 70 L66 50 L78 50 Z" />
          <path class="avatar-ink" d="M50 84 L50 92" />
        </symbol>
        <symbol id="a-sun" viewBox="0 0 100 100">
          <circle class="avatar-ink" cx="50" cy="50" r="18" />
          <path class="avatar-ink" d="M50 14 L50 22 M50 78 L50 86 M14 50 L22 50 M78 50 L86 50 M24 24 L30 30 M70 70 L76 76 M76 24 L70 30 M30 70 L24 76" />
        </symbol>
        <symbol id="a-moon" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M70 18 C50 18 32 32 32 52 C32 72 50 86 70 86 C58 80 50 66 50 52 C50 38 58 24 70 18 Z" />
          <circle class="avatar-ink-fill" cx="78" cy="34" r="2" />
          <circle class="avatar-ink-fill" cx="84" cy="50" r="2.5" />
          <circle class="avatar-ink-fill" cx="74" cy="68" r="2" />
        </symbol>
        <symbol id="a-star" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 14 L60 40 L88 42 L66 60 L74 86 L50 70 L26 86 L34 60 L12 42 L40 40 Z" />
        </symbol>
        <symbol id="a-cloud" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M28 70 C16 70 14 54 24 50 C24 38 38 32 46 38 C50 28 66 28 70 40 C82 38 88 54 80 62 C82 70 76 78 68 76 C66 82 56 84 52 78 C46 84 32 80 28 70 Z" />
        </symbol>
        <symbol id="a-rainbow" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M12 74 C12 50 30 30 50 30 C70 30 88 50 88 74" />
          <path class="avatar-ink" d="M22 74 C22 56 36 42 50 42 C64 42 78 56 78 74" />
          <path class="avatar-ink" d="M32 74 C32 62 40 54 50 54 C60 54 68 62 68 74" />
          <circle class="avatar-ink" cx="14" cy="80" r="6" />
          <circle class="avatar-ink" cx="86" cy="80" r="6" />
        </symbol>
        <symbol id="a-bolt" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M56 14 L26 58 L46 58 L40 86 L74 40 L54 40 Z" />
        </symbol>
        <symbol id="a-umbrella" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M14 52 C14 30 30 16 50 16 C70 16 86 30 86 52 L14 52 Z" />
          <path class="avatar-ink" d="M14 52 C20 46 28 46 34 52 C40 46 46 46 50 52 C54 46 60 46 66 52 C72 46 80 46 86 52" />
          <path class="avatar-ink" d="M50 16 L50 76 C50 82 46 86 40 86 C34 86 30 82 30 76" />
        </symbol>
        <symbol id="a-balloon" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 14 C32 14 22 30 22 46 C22 60 34 72 50 72 C66 72 78 60 78 46 C78 30 68 14 50 14 Z" />
          <path class="avatar-ink" d="M46 72 L54 72 L52 78 L48 78 Z" />
          <path class="avatar-ink" d="M50 78 C48 84 54 88 50 92" />
        </symbol>
        <symbol id="a-kite" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 12 L82 44 L50 76 L18 44 Z" />
          <path class="avatar-ink" d="M50 12 L50 76" />
          <path class="avatar-ink" d="M18 44 L82 44" />
          <path class="avatar-ink" d="M50 76 C46 80 54 84 50 88 C46 92 54 96 50 96" />
        </symbol>
        <symbol id="a-hotair" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M22 42 C22 22 36 12 50 12 C64 12 78 22 78 42 C78 54 70 64 58 68 L42 68 C30 64 22 54 22 42 Z" />
          <path class="avatar-ink" d="M50 12 L50 68" />
          <path class="avatar-ink" d="M36 14 C32 26 32 56 42 68" />
          <path class="avatar-ink" d="M64 14 C68 26 68 56 58 68" />
          <path class="avatar-ink" d="M42 68 L40 80 L60 80 L58 68" />
          <path class="avatar-ink" d="M42 80 L46 90 L54 90 L58 80" />
        </symbol>
        <symbol id="a-rocket" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 10 C36 24 32 42 32 60 L32 74 L68 74 L68 60 C68 42 64 24 50 10 Z" />
          <circle class="avatar-ink" cx="50" cy="44" r="7" />
          <path class="avatar-ink" d="M32 60 L18 70 L24 80 L32 74" />
          <path class="avatar-ink" d="M68 60 L82 70 L76 80 L68 74" />
          <path class="avatar-ink" d="M42 74 L38 90 M58 74 L62 90 M50 76 L50 92" />
        </symbol>
        <symbol id="a-boat" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 14 L50 64 L20 64 Z" />
          <path class="avatar-ink" d="M50 22 L78 64 L50 64" />
          <path class="avatar-ink" d="M14 70 L86 70 L78 84 L22 84 Z" />
          <path class="avatar-ink" d="M14 84 C20 90 30 90 36 86 C42 90 52 90 58 86 C64 90 74 90 80 86" />
        </symbol>
        <symbol id="a-cupcake" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M26 52 L74 52 L68 84 L32 84 Z" />
          <path class="avatar-ink" d="M30 60 L70 60 M34 70 L66 70" />
          <path class="avatar-ink" d="M22 52 C22 36 38 30 50 36 C58 26 78 32 78 48 C82 50 82 58 76 58 L24 58 C18 58 18 50 22 52 Z" />
          <path class="avatar-ink" d="M50 20 L50 32" />
          <circle class="avatar-ink" cx="50" cy="18" r="3" />
        </symbol>
        <symbol id="a-donut" viewBox="0 0 100 100">
          <circle class="avatar-ink" cx="50" cy="50" r="34" />
          <circle class="avatar-ink" cx="50" cy="50" r="12" />
          <path class="avatar-ink" d="M22 38 C28 28 38 22 50 22" />
          <path class="avatar-ink" d="M62 24 L66 18 M40 28 L36 22 M76 36 L82 32 M30 56 L24 58 M76 60 L82 64 M42 74 L38 80 M64 76 L68 82" />
        </symbol>
        <symbol id="a-icecream" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M28 42 C28 28 38 18 50 18 C62 18 72 28 72 42 L28 42 Z" />
          <circle class="avatar-ink" cx="40" cy="38" r="3" />
          <circle class="avatar-ink" cx="50" cy="32" r="3" />
          <circle class="avatar-ink" cx="60" cy="38" r="3" />
          <path class="avatar-ink" d="M28 42 L50 90 L72 42" />
          <path class="avatar-ink" d="M36 54 L60 54 M40 64 L56 64 M44 74 L52 74" />
        </symbol>
        <symbol id="a-coffee" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M22 30 L70 30 L66 84 L26 84 Z" />
          <path class="avatar-ink" d="M70 40 C82 40 82 60 70 60" />
          <path class="avatar-ink" d="M36 16 C32 22 40 24 36 30" />
          <path class="avatar-ink" d="M50 14 C46 20 54 24 50 30" />
        </symbol>
        <symbol id="a-pizza" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M50 14 L18 80 L82 80 Z" />
          <path class="avatar-ink" d="M28 70 L72 70" />
          <circle class="avatar-ink-fill" cx="42" cy="58" r="3.5" />
          <circle class="avatar-ink-fill" cx="58" cy="58" r="3.5" />
          <circle class="avatar-ink-fill" cx="50" cy="72" r="3.5" />
          <circle class="avatar-ink-fill" cx="50" cy="42" r="3" />
        </symbol>
        <symbol id="a-fish" viewBox="0 0 100 100">
          <path class="avatar-ink" d="M14 50 C24 30 50 24 66 30 C78 34 86 44 86 50 C86 56 78 66 66 70 C50 76 24 70 14 50 Z" />
          <path class="avatar-ink" d="M14 50 C8 42 4 38 4 30 C12 32 18 38 22 44" />
          <path class="avatar-ink" d="M14 50 C8 58 4 62 4 70 C12 68 18 62 22 56" />
          <circle class="avatar-ink-fill" cx="70" cy="46" r="3" />
          <path class="avatar-ink" d="M50 38 C54 44 54 56 50 62" />
        </symbol>
      </defs>
    </svg>
    """
  end
end
