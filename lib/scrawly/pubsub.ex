defmodule Scrawly.PubSub do
  @moduledoc """
  PubSub wrapper for Ash.Notifier.PubSub.

  Ash's PubSub notifier calls `module.broadcast(topic, event, notification)`.
  This module bridges that call to `Phoenix.PubSub.broadcast/3`, transforming
  the Ash notification into the message format expected by GamePage's handle_info.

  The Phoenix.PubSub server is also registered under the name `Scrawly.PubSub`
  (started in Application). Module names and process names are independent in
  Elixir, so both coexist without conflict.
  """

  @pubsub_name __MODULE__

  def broadcast(topic, _event, notification) do
    event_atom = extract_event(topic)
    room_id = extract_room_id(topic)
    data = extract_data(notification)

    message = {event_atom, %{room_id: room_id, data: data}}
    Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
  end

  defp extract_event(topic) do
    topic
    |> String.split(":")
    |> Enum.at(1)
    |> String.to_atom()
  end

  defp extract_room_id(topic) do
    topic
    |> String.split(":")
    |> Enum.at(2)
  end

  defp extract_data(%{data: %Ash.Changeset.OriginalDataNotAvailable{}}), do: nil
  defp extract_data(%{data: data}), do: data
  defp extract_data(_), do: nil
end
