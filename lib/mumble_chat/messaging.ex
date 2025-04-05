defmodule MumbleChat.Messaging do
  @moduledoc """
  Message handling functionality for the Mumble client.

  This module provides functionality to handle text messages, parse commands,
  and send feedback messages to the Mumble server.
  """

  require Logger

  @doc """
  Parses and handles a text message, checking for commands.

  ## Parameters

  - `message`: The received text message
  - `actor`: Session ID of the sender
  - `socket`: The SSL socket connection
  - `session_id`: The current session ID
  - `channel_id`: The current channel ID

  ## Returns

  `:ok`
  """
  def handle_text_command(message, actor, socket, session_id, channel_id) do
    target_channel = channel_id

    case parse_play_command(message) do
      {:play, url} ->
        Logger.info("Received !play command with URL: #{url}")
        handle_play_command(url, socket, session_id, channel_id)
        :ok

      _ ->
        # Not a recognized command, check for other commands
        :ok
    end

    case parse_pause_command(message) do
      {:pause} ->
        Logger.info("Received !pause command")
        handle_pause_command(socket, session_id, channel_id)
        :ok

      _ ->
        # Not a recognized command, check for other commands
        :ok
    end

    case parse_resume_command(message) do
      {:resume} ->
        Logger.info("Received !resume command")
        handle_resume_command(socket, session_id, channel_id)
        :ok

      _ ->
        # Not a recognized command, ignore
        :ok
    end
  end

  @doc """
  Sends a text message to a channel on the Mumble server.

  ## Parameters

  - `socket`: The SSL socket connection
  - `message_type`: The message type (11 for TextMessage)
  - `text`: The message text to send
  - `channel_id`: The ID of the channel to send the message to
  - `session_id`: The sender's session ID
  """
  def send_text_message(socket, message_type, text, channel_id, session_id) do
    message_data = MumbleChat.ProtobufHelper.create_text_message(text, channel_id, session_id)
    send_message(socket, message_type, message_data)
  end

  @doc """
  Sends a message to the Mumble server.

  Formats the message with the appropriate header containing the message type and length.
  """
  def send_message(socket, message_type, message_data) do
    header = <<message_type::size(16), byte_size(message_data)::size(32)>>
    Logger.debug("Sending message type: #{message_type}, length: #{byte_size(message_data)}")

    result = :ssl.send(socket, [header, message_data])

    case result do
      :ok ->
        Logger.debug("Message sent successfully")
        :ok

      error ->
        Logger.error("Failed to send message: #{inspect(error)}")
        error
    end
  end

  # Parse a message to check if it's a !play command
  defp parse_play_command(message) when is_binary(message) do
    # Trim whitespace and check if it starts with !play
    case String.trim(message) do
      "!play " <> rest ->
        # Extract the URL from the rest of the message and handle HTML formatting
        url = rest |> String.trim() |> extract_url_from_html()
        {:play, url}

      _ ->
        :not_play_command
    end
  end

  # parse pause message
  defp parse_pause_command(message) do
    # Trim whitespace and check if it starts with !pause
    case String.trim(message) do
      "!pause" ->
        {:pause}

      _ ->
        :not_pause_command
    end
  end

  # parse resume message
  defp parse_resume_command(message) do
    # Trim whitespace and check if it starts with !resume
    case String.trim(message) do
      "!resume" ->
        {:resume}

      _ ->
        :not_resume_command
    end
  end

  # Extract URL from HTML <a> tags if present
  defp extract_url_from_html(text) do
    cond do
      # Case 1: Text contains an <a> tag with href attribute
      String.contains?(text, "<a href=") ->
        # Extract the URL from the href attribute
        case Regex.run(~r/<a href="([^"]+)"/, text, capture: :all_but_first) do
          [url] -> url
          # Fallback to original text if regex doesn't match
          _ -> text
        end

      # Case 2: No HTML formatting, return the text as is
      true ->
        text
    end
  end

  # Handle a play command with the given URL
  defp handle_play_command(url, socket, session_id, channel_id) do
    # Send a message indicating we're processing the request
    send_feedback_message(
      "Processing !play request for: #{url}",
      socket,
      session_id,
      channel_id
    )

    # Use MediaDownloader to download the audio
    # Set a reasonable max size (100MB)
    max_size_bytes = 100 * 1024 * 1024

    # Start the download in a separate process to not block the GenServer
    Task.start(fn ->
      pid = Process.whereis(MumbleChat.Client)

      case MediaDownloader.download_audio(url, max_size_bytes) do
        {:ok, file_path} ->
          # Download successful, send feedback and start playback via PlaybackController
          GenServer.call(
            pid,
            {:get_state_for_feedback,
             fn state ->
               send_feedback_message(
                 "Download complete. Starting playback...",
                 socket,
                 session_id,
                 channel_id
               )
             end}
          )

          # Use the PlaybackController to play the file
          case MumbleChat.PlaybackController.play(file_path) do
            :ok ->
              Logger.info("Playback started via PlaybackController")

            {:error, reason} ->
              GenServer.call(
                pid,
                {:get_state_for_feedback,
                 fn state ->
                   send_feedback_message(
                     "Error starting playback: #{inspect(reason)}",
                     socket,
                     session_id,
                     channel_id
                   )
                 end}
              )
          end

        {:error, :invalid_url} ->
          GenServer.call(
            pid,
            {:get_state_for_feedback,
             fn state ->
               send_feedback_message(
                 "Error: Invalid URL provided",
                 socket,
                 session_id,
                 channel_id
               )
             end}
          )

        {:error, {:yt_dlp_error, error}} ->
          GenServer.call(
            pid,
            {:get_state_for_feedback,
             fn state ->
               send_feedback_message(
                 "Error downloading audio: #{inspect(error)}",
                 socket,
                 session_id,
                 channel_id
               )
             end}
          )

        {:error, {:file_too_large, size, max}} ->
          GenServer.call(
            pid,
            {:get_state_for_feedback,
             fn state ->
               send_feedback_message(
                 "Error: File too large (#{size} bytes, max: #{max} bytes)",
                 socket,
                 session_id,
                 channel_id
               )
             end}
          )

        {:error, reason} ->
          GenServer.call(
            pid,
            {:get_state_for_feedback,
             fn state ->
               send_feedback_message(
                 "Error: #{inspect(reason)}",
                 socket,
                 session_id,
                 channel_id
               )
             end}
          )
      end
    end)
  end

  # Handle a pause command
  defp handle_pause_command(socket, session_id, channel_id) do
    Logger.info("Handling !pause command")

    case MumbleChat.PlaybackController.pause() do
      :ok ->
        send_feedback_message(
          "Playback paused",
          socket,
          session_id,
          channel_id
        )

      {:error, :not_playing} ->
        send_feedback_message(
          "Nothing is currently playing",
          socket,
          session_id,
          channel_id
        )

      {:error, reason} ->
        send_feedback_message(
          "Error pausing playback: #{inspect(reason)}",
          socket,
          session_id,
          channel_id
        )
    end
  end

  # Handle a resume command
  defp handle_resume_command(socket, session_id, channel_id) do
    Logger.info("Handling !resume command")

    case MumbleChat.PlaybackController.resume() do
      :ok ->
        send_feedback_message(
          "Playback resumed",
          socket,
          session_id,
          channel_id
        )

      {:error, :not_paused} ->
        send_feedback_message(
          "Playback is not paused",
          socket,
          session_id,
          channel_id
        )

      {:error, reason} ->
        send_feedback_message(
          "Error resuming playback: #{inspect(reason)}",
          socket,
          session_id,
          channel_id
        )
    end
  end

  # Send a feedback message to the channel
  defp send_feedback_message(text, socket, session_id, channel_id) do
    # Create a text message with the right ids
    message_data = MumbleChat.ProtobufHelper.create_text_message(text, channel_id, session_id)

    # Send as TextMessage (type 11)
    send_message(socket, 11, message_data)
  end
end
