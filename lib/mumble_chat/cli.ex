defmodule MumbleChat.CLI do
  @moduledoc """
  Command-line interface for interacting with MumbleChat.
  """

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
    IO.puts("Type 'exit' to quit.")
    message_loop()
  end

  defp message_loop do
    case IO.gets("> ") do
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
