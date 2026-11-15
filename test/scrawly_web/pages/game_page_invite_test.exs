defmodule ScrawlyWeb.Pages.GamePageInviteTest do
  @moduledoc """
  The lobby's "copy invite link" (invites). The page asks room_links.mjs to
  copy `<origin>/r/<CODE>`, built in the browser from window.location.origin
  (the server never builds the link), and room_links.mjs answers with
  `:invite_link_copied`: "copied" for 2 seconds, or, when the browser
  refused, the link shown and selected to copy by hand.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers
  import Scrawly.SessionTestHelpers

  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Template.Renderer
  alias Scrawly.JsCallTrace
  alias ScrawlyWeb.Pages.GamePage

  @moduletag :capture_log

  setup do
    creator = create_user()
    room = start_room(creator)
    server = run_page_middleware(GamePage, session_server(creator))

    {component, _server} =
      GamePage.init(%{room_id: room.id}, %Component{props: %{room_id: room.id}}, server)

    %{room: room, lobby: %{component | next_action: nil}}
  end

  defp render(component) do
    {html, _registry, _server} =
      GamePage.template().(Map.merge(component.props, component.state))
      |> Renderer.render_dom(%Renderer.Env{}, %Hologram.Server{})

    html
  end

  defp copied(component),
    do: GamePage.action(:invite_link_copied, %{copied: true, link: "x"}, component)

  test "the lobby starts with the button idle", %{lobby: lobby} do
    assert lobby.state.invite_copy == :idle
    assert lobby.state.invite_link == nil

    html = render(lobby)
    assert html =~ lobby.state.room_code

    assert html =~
             ~r{<button type="button" class="app-btn app-btn-sm">\s*copy invite link\s*</button>}

    assert html =~ "send the link or the code to your friends"
    refute html =~ "share the code to invite friends"
    refute html =~ ~s(id="invite-link")
  end

  test "the button asks the browser to copy the room's code; nothing is built here", %{
    lobby: lobby,
    room: room
  } do
    {result, calls} =
      JsCallTrace.js_calls(fn -> GamePage.action(:copy_invite_link, %{}, lobby) end)

    assert calls == [{:copyInviteLink, [room.code]}]
    assert result.state == lobby.state
  end

  test "copied: the button says so for 2 seconds", %{lobby: lobby} do
    result = copied(lobby)

    assert result.state.invite_copy == :copied
    assert result.state.invite_copy_gen == 1

    assert %Action{name: :reset_invite_copy, delay: 2_000, params: %{gen: 1}} =
             result.next_action

    assert render(result) =~
             ~r{<button type="button" class="app-btn app-btn-sm">\s*copied\s*</button>}

    reset = GamePage.action(:reset_invite_copy, %{gen: 1}, result)
    assert reset.state.invite_copy == :idle
  end

  test "an earlier copy's timer doesn't cut a later one short", %{lobby: lobby} do
    twice = lobby |> copied() |> copied()
    assert twice.state.invite_copy_gen == 2

    early = GamePage.action(:reset_invite_copy, %{gen: 1}, twice)
    assert early.state.invite_copy == :copied

    assert GamePage.action(:reset_invite_copy, %{gen: 2}, twice).state.invite_copy == :idle
  end

  test "refused: the link is shown and selected, to copy by hand", %{lobby: lobby} do
    link = "http://localhost:4023/r/" <> lobby.state.room_code

    {result, calls} =
      JsCallTrace.js_calls(fn ->
        GamePage.action(:invite_link_copied, %{copied: false, link: link}, lobby)
      end)

    assert calls == [{:selectInviteLink, ["invite-link"]}]
    assert result.state.invite_copy == :manual
    assert result.state.invite_link == link

    html = render(result)
    assert html =~ ~s(id="invite-link")
    assert html =~ ~s(value="#{link}")
    assert html =~ "readonly"
    assert html =~ "copy this link"

    # A later copy that works hides it again.
    again = copied(result)
    assert again.state.invite_copy == :copied
    assert again.state.invite_link == nil
    refute render(again) =~ ~s(id="invite-link")
  end

  test "an answer without a usable link changes nothing", %{lobby: lobby} do
    for params <- [%{}, %{copied: false}, %{copied: false, link: 42}, %{copied: "yes"}] do
      assert GamePage.action(:invite_link_copied, params, lobby) == lobby
    end
  end

  test "a Back/Forward restore puts a copied button back to idle", %{lobby: lobby} do
    shown = %{copied(lobby) | next_action: nil}
    shown = put_in(shown.state.page_shown?, true)

    restored = GamePage.action(:page_shown, %{mount_id: shown.state.mount_id}, shown)
    assert restored.state.invite_copy == :idle
  end
end
