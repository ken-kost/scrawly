defmodule Scrawly.Accounts.Changes.GenerateUsernameFromEmail do
  @moduledoc """
  Generates a username from the user's email address during registration.
  Takes everything before the @ symbol and appends a unique integer.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :email) do
      nil ->
        email = "unknown#{System.unique_integer([:positive])}@test.org"
        username = generate_username_from_email(email)

        Ash.Changeset.change_attribute(changeset, :username, username)
        |> Ash.Changeset.change_attribute(:email, email)

      email ->
        username = generate_username_from_email(email)
        Ash.Changeset.change_attribute(changeset, :username, username)
    end
  end

  defp generate_username_from_email(email) do
    email
    |> to_string()
    |> String.split("@")
    |> List.first()
    # Remove invalid characters
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "")
    # Limit to 15 characters for the base
    |> String.slice(0, 15)
  end
end
