defmodule ScrawlyWeb.HologramAuth do
  @moduledoc """
  Authentication helpers for Hologram pages.
  Provides functions to check authentication status and redirect unauthenticated users.
  """

  require Ash.Query

  alias Scrawly.Accounts.User

  @doc """
  Checks if a user is authenticated based on session data and returns the user or redirects to sign-in.

  ## Parameters
  - component: The Hologram component
  - server: The Hologram server containing session data
  - redirect_page: The page module to redirect to if not authenticated (default: sign-in)

  ## Returns
  - `{:ok, component, user}` if authenticated
  - `{:redirect, component}` if not authenticated (component will have redirect set)
  """
  def require_authentication(component, server, redirect_page \\ nil) do
    case get_current_user(server) do
      {:ok, user} ->
        {:ok, component, user}

      {:error, :not_authenticated} ->
        # Store the current path for redirect after authentication
        current_path = get_current_path(server)

        redirect_component =
          if redirect_page do
            put_page(component, redirect_page)
          else
            # Redirect to sign-in page - we'll need to determine the correct sign-in route
            put_page_redirect(component, "/auth/register", current_path)
          end

        {:redirect, redirect_component}
    end
  end

  @doc """
  Checks if a user is authenticated and returns user data if available.
  Does not redirect - allows pages to handle authentication state themselves.

  ## Returns
  - `{:ok, user}` if authenticated
  - `{:error, :not_authenticated}` if not authenticated
  """
  def get_current_user(server) do
    IO.inspect(server, label: "Server in get_current_user")

    case get_session(server, "user_token") do
      nil ->
        {:error, :not_authenticated}

      user_data when is_map(user_data) ->
        IO.puts("Found user data in session: #{inspect(user_data)}")
        # User data is already in session
        {:ok, user_data}

      user_token when is_binary(user_token) ->
        IO.puts("Found user_token string in session: #{inspect(user_token)}")
        # Session contains user ID, load full user
        load_user_by_token(user_token) |> dbg()

      other ->
        IO.puts("Found unexpected session data: #{inspect(other)}")
        {:error, :not_authenticated}
    end
  end

  @doc """
  Adds user data to component state.
  """
  def put_user_state(component, user) do
    component
    |> put_state(:current_user_id, user.id)
    |> put_state(:current_user_email, user.email)
    |> put_state(:current_user_username, user.username)
    |> put_state(:authenticated, true)
  end

  @doc """
  Adds unauthenticated state to component.
  """
  def put_unauthenticated_state(component) do
    component
    |> put_state(:current_user_id, nil)
    |> put_state(:current_user_email, nil)
    |> put_state(:current_user_username, nil)
    |> put_state(:authenticated, false)
  end

  # Private functions

  defp load_user_by_token(user_token) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{"token" => user_token}) do
      {:ok, user} when not is_nil(user) ->
        {:ok, user}

      error ->
        dbg(error)
        {:error, :not_authenticated}
    end
  end

  defp get_session(server, key) do
    case server.session do
      %{^key => value} -> value
      _ -> nil
    end
  end

  defp get_current_path(server) do
    # Extract current path from server context if available
    # This is a placeholder - we may need to adjust based on how Hologram provides this
    case server do
      %{request_path: path} -> path
      _ -> "/"
    end
  end

  defp put_page(component, page_module) do
    %{component | next_page: {page_module, %{}}}
  end

  defp put_page_redirect(component, redirect_path, _return_to) do
    # For now, we'll redirect to the sign-in path
    # In a real implementation, we might need to store return_to in session
    %{component | next_page: {:redirect, redirect_path}}
  end

  defp put_state(component, key, value) do
    current_state = component.state || %{}
    new_state = Map.put(current_state, key, value)
    %{component | state: new_state}
  end
end
