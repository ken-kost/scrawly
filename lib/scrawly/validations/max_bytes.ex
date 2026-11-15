defmodule Scrawly.Validations.MaxBytes do
  @moduledoc """
  Caps a string attribute's size in bytes: `validate {MaxBytes, attribute:
  :username, max: 80}`.

  String constraints (`max_length`) count characters, and one character can
  be megabytes ("a" followed by combining marks), so every user-typed
  attribute that is stored and shown to others carries a byte cap as well
  (`Scrawly.Text` cuts chat lines the same way).

  Passes when the attribute is not changing or is set to nil. Runs through
  `validate/3` in creates and non-atomic updates; in atomic updates the
  condition goes into the UPDATE (`octet_length`), so the stored value is
  never read first.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]) and is_integer(opts[:max]) and opts[:max] > 0,
      do: {:ok, opts},
      else: {:error, "MaxBytes needs an :attribute and a positive integer :max"}
  end

  @impl true
  def validate(changeset, opts, context) do
    attribute = opts[:attribute]

    with true <- Ash.Changeset.changing_attribute?(changeset, attribute),
         value when is_binary(value) <- changeset_value(changeset, attribute),
         true <- byte_size(value) > opts[:max] do
      {:error,
       InvalidAttribute.exception(
         field: attribute,
         message: message(context, opts),
         vars: [max: opts[:max]]
       )}
    else
      _ -> :ok
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    attribute = opts[:attribute]

    if Ash.Changeset.changing_attribute?(changeset, attribute) do
      {:atomic, [attribute],
       expr(fragment("octet_length(?)", ^atomic_ref(attribute)) > ^opts[:max]),
       expr(
         error(^InvalidAttribute, %{
           field: ^attribute,
           message: ^message(context, opts),
           vars: %{max: ^opts[:max]}
         })
       )}
    else
      :ok
    end
  end

  # CiString attributes (the email) hold a struct.
  defp changeset_value(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      %Ash.CiString{} = value -> to_string(value)
      value -> value
    end
  end

  defp message(%{message: message}, _opts) when is_binary(message), do: message
  defp message(_context, opts), do: "must be at most #{opts[:max]} bytes"
end
