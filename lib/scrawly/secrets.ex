defmodule Scrawly.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Scrawly.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:scrawly, :token_signing_secret)
  end
end
