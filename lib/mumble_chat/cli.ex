defmodule MumbleChat.CLI do
  @moduledoc """
  Command-line interface for interacting with MumbleChat.
  """
  require Logger

  @doc """
  Starts an interactive loop to send messages.
  Messages starting with '/channel ' will be sent to the specified channel number.
  All other messages will be sent to the current channel.
  Type 'exit' to quit.
  """
  def start do
    # Start the application if it's not already started
    {:ok, _} = Application.ensure_all_started(:mumble_chat)

    IO.puts("MumbleChat CLI started. Type your message and press Enter.")
    IO.puts("Use '/channel <number> <message>' to send to specific channel.")
    IO.puts("Use '/join <number>' to join a specific channel.")
    IO.puts("Use '/status' to check connection status.")
    IO.puts("Type 'exit' to quit.")

    # Give the client some time to connect before accepting input
    Process.sleep(1000)

    message_loop()
  end

  defp message_loop do
    case IO.gets("> ") do
      :eof ->
        IO.puts("Input stream closed. Exiting.")

      "exit\n" ->
        IO.puts("Goodbye!")

      "/channel " <> rest ->
        case parse_channel_message(rest) do
          {:ok, channel_id, message} ->
            IO.puts("Sending to channel #{channel_id}: '#{message}'")
            MumbleChat.Client.send_message(message, channel_id)
            message_loop()

          :error ->
            IO.puts("Invalid format. Use '/channel <number> <message>'")
            message_loop()
        end

      "/join " <> channel_str ->
        case Integer.parse(String.trim(channel_str)) do
          {channel_id, ""} ->
            IO.puts("Joining channel #{channel_id}...")
            MumbleChat.Client.join_channel(channel_id)
            message_loop()

          _ ->
            IO.puts("Invalid format. Use '/join <number>'")
            message_loop()
        end

      "/status\n" ->
        # Get connection status from GenServer
        case :sys.get_state(MumbleChat.Client) do
          %{socket: nil} ->
            IO.puts("❌ Not connected to server")

          %{session_id: nil} ->
            IO.puts("🔄 Connected to server but authentication not complete")

          %{session_id: session_id, current_channel_id: nil} ->
            IO.puts("✅ Connected as session #{session_id}, but not in any channel")

          %{session_id: session_id, current_channel_id: channel_id} ->
            IO.puts("✅ Connected as session #{session_id} in channel #{channel_id}")
        end

        message_loop()

      input ->
        # Remove the trailing newline
        message = String.trim(input)
        IO.puts("Sending to current channel: '#{message}'")
        MumbleChat.Client.send_message(message)
        message_loop()
    end
  end

  defp parse_channel_message(text) do
    case String.split(text, " ", parts: 2) do
      [channel_str, message] ->
        case Integer.parse(channel_str) do
          {channel_id, ""} -> {:ok, channel_id, String.trim(message)}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
