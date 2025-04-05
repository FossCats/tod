defmodule MumbleChat do
  @moduledoc """
  MumbleChat client that connects to a Mumble server and prints chat messages to the console.
  """

  @doc """
  Starts the Mumble chat client.
  """
  def main(args \\ []) do
    Application.start(:mumble_chat)
    Process.sleep(:infinity)
  end
end
