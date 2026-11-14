defmodule Scrawly.Accounts.RecoveryCode do
  @moduledoc """
  Account recovery codes: 100 random bits shown to the user as 20 Crockford
  base32 characters in groups of four (`XXXX-XXXX-XXXX-XXXX-XXXX`).

  A code can only set a new password (see the User `:reset_password_with_recovery_code`
  action); it never signs anyone in by itself. Only a bcrypt hash of the
  normalized form is stored, so `normalize/1` must be applied both when hashing
  and when verifying.
  """

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @bits 100
  @group 4

  @doc """
  A fresh code in display form. 13 random bytes give 104 bits; the first 100
  become 20 base32 characters.
  """
  @spec generate() :: String.t()
  def generate do
    <<bits::bitstring-size(@bits), _rest::bitstring>> = :crypto.strong_rand_bytes(13)

    bits
    |> encode()
    |> format()
  end

  @doc """
  Canonical form of user input: uppercase, without whitespace or hyphens, with
  the look-alikes O -> 0 and I / L -> 1. Never fails; garbage stays garbage
  and simply won't verify.
  """
  @spec normalize(term) :: String.t()
  def normalize(input) when is_binary(input) do
    input
    |> String.upcase()
    |> String.replace(~r/[\s\-]+/u, "")
    |> String.replace("O", "0")
    |> String.replace(["I", "L"], "1")
  end

  def normalize(_), do: ""

  @doc "Groups a normalized code as `XXXX-XXXX-XXXX-XXXX-XXXX`."
  @spec format(String.t()) :: String.t()
  def format(code) when is_binary(code) do
    code
    |> normalize()
    |> String.graphemes()
    |> Enum.chunk_every(@group)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp encode(<<>>), do: ""

  defp encode(<<chunk::5, rest::bitstring>>),
    do: <<Enum.at(@alphabet, chunk)>> <> encode(rest)
end
