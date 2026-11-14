defmodule Scrawly.Accounts.User.Validations.NotReservedUsername do
  @moduledoc """
  Rejects usernames that could pass for the game itself: "System" (chat lines
  from the server use it as their speaker), compared case-insensitively after
  trimming, and any name with leading or trailing whitespace.

  Passes when `:username` is not changing or is being set to nil. Runs
  atomically in update actions (the condition is pushed into the UPDATE, or
  evaluated up front when the new value is a literal) and through
  `validate/3` in creates and non-atomic updates.

  Only exact matches are reserved: "systemfan" or "the system" are fine.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @reserved ["system"]
  @reserved_message "is reserved"
  @whitespace_message "can't start or end with whitespace"

  @doc "True for a name that trims and downcases to a reserved name."
  @spec reserved?(term) :: boolean
  def reserved?(name) when is_binary(name),
    do: String.downcase(String.trim(name)) in @reserved

  def reserved?(_name), do: false

  @impl true
  def validate(changeset, _opts, context) do
    if Ash.Changeset.changing_attribute?(changeset, :username) do
      changeset
      |> Ash.Changeset.get_attribute(:username)
      |> check(context)
    else
      :ok
    end
  end

  # Atomic updates turn every accepted input into an atomic, even one equal to
  # the stored value, so "not changing" is part of the condition here: a row
  # that already holds a reserved name (it predates this rule) can still save
  # its other fields. That comparison reads the stored row, so a reserved new
  # value is checked in the UPDATE itself.
  @impl true
  def atomic(changeset, _opts, context) do
    if Ash.Changeset.changing_attribute?(changeset, :username) do
      [
        {:atomic, [:username],
         expr(
           string_downcase(string_trim(^atomic_ref(:username))) in ^@reserved and
             (is_nil(username) or ^atomic_ref(:username) != username)
         ), error_expr(context, @reserved_message)},
        {:atomic, [:username],
         expr(string_trim(^atomic_ref(:username)) != ^atomic_ref(:username)),
         error_expr(context, @whitespace_message)}
      ]
    else
      :ok
    end
  end

  defp check(name, context) when is_binary(name) do
    cond do
      reserved?(name) -> invalid(name, context, @reserved_message)
      String.trim(name) != name -> invalid(name, context, @whitespace_message)
      true -> :ok
    end
  end

  defp check(_name, _context), do: :ok

  defp invalid(name, context, default_message) do
    {:error,
     InvalidAttribute.exception(
       field: :username,
       value: name,
       message: message(context, default_message)
     )}
  end

  defp error_expr(context, default_message) do
    expr(
      error(^InvalidAttribute, %{
        field: :username,
        value: ^atomic_ref(:username),
        message: ^message(context, default_message)
      })
    )
  end

  defp message(%{message: message}, _default) when is_binary(message), do: message
  defp message(_context, default), do: default
end
