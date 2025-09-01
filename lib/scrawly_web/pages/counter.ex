defmodule ScrawleyWeb.Components.Counter do
  use Hologram.Page

  route "/counter"

  layout Scrawly.AppLayout

  def init(_params, component, _server) do
    IO.inspect(component)

    component
    |> put_state(:count, 0)
  end

  def template do
    ~HOLO"""
    <div>
      <p>Count: {@count}</p>
      <button $click={:increment, step: 1}> +1 </button>
    </div>
    """
  end

  def action(:increment, params, component) do
    new_count = component.state.count + params.step
    IO.inspect(new_count)

    component
    |> put_state(:count, new_count)
  end
end
