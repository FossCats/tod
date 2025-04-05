defmodule MumbleChat do
  @moduledoc """
  MumbleChat client that connects to a Mumble server and prints chat messages to the console.
  """

  @doc """
  Starts the Mumble chat client.
  """
  def main(args \\ []) do
    # Parse command line arguments if needed
    Application.start(:mumble_chat)

    # Keep the application running
    Process.sleep(:infinity)
  end
end
