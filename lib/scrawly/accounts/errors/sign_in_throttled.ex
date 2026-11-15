defmodule Scrawly.Accounts.Errors.SignInThrottled do
  @moduledoc """
  A password sign-in refused before the password was checked: too many recent
  attempts for that email or from that client (`Scrawly.Accounts.Throttle`).
  """

  use Splode.Error, fields: [], class: :forbidden

  def message(_error), do: "too many sign-in attempts, try again in a few minutes"
end
