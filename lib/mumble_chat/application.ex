defmodule MumbleChat.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {MumbleChat.Client, []}
    ]

    opts = [strategy: :one_for_one, name: MumbleChat.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
