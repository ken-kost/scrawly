# event handling

def init(_params, component, _server) do
  put_state(component, drawing?: false, path: "")
end

def action(:clear_canvas, _params, component) do
  put_state(component, drawing?: false, path: "")
end

def action(:draw_move, params, %{state: %{drawing?: true}} = component) do
  new_path = component.state.path <> " L #{params.event.offset_x} #{params.event.offset_y}"
  put_state(component, :path, new_path)
end

def action(:draw_move, _params, component) do
  component
end

def action(:start_drawing, params, component) do
  new_path = component.state.path <> " M #{params.event.offset_x} #{params.event.offset_y}"
  put_state(component, drawing?: true, path: new_path)
end

def action(:stop_drawing, _params, component) do
  put_state(component, :drawing?, false)
end


# template

(...)
  <button $click="clear_canvas" class={Button.class(:md)}>Clear</button>
</div>
<svg 
  class="bg-[#0F1014] cursor-crosshair border border-[#363636] rounded w-full h-[70vh]"
  style="touch-action: none;"
  $pointer_down="start_drawing"
  $pointer_move="draw_move"
  $pointer_up="stop_drawing"
  $pointer_cancel="stop_drawing"
>
  <path d={@path} stroke="#C2BBD3" stroke-width="2" fill="none" />
</svg>