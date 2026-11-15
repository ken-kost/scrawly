defmodule Scrawly.Accounts.Errors.RecoveryRejected do
  @moduledoc """
  The only error a recovery-code reset returns once its inputs are valid.

  `reason: :incorrect` covers a wrong code, an unknown email, a guest and an
  account without a code alike, so the text never says which one it was.
  `reason: :throttled` means too many recent failures for that email.
  """

  use Splode.Error, fields: [reason: :incorrect], class: :invalid

  def message(error), do: text(error)

  @doc "The user-facing text, without the bread crumbs `message/1` gains from Splode."
  @spec text(Exception.t()) :: String.t()
  def text(%__MODULE__{reason: :throttled}), do: "too many attempts, try again in a few minutes"
  def text(%__MODULE__{}), do: "email or recovery code is incorrect"
end
