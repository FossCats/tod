#!/usr/bin/env elixir

# This script tests the full audio encoding and Mumble playback process
# It will convert an audio file to Opus format and stream it to a Mumble server

# Configuration (modify these as needed)
test_audio_url = "https://cdn.pixabay.com/download/audio/2023/04/21/audio_56df6057ea.mp3?filename=tropical-beat-159295.mp3"
mumble_host = System.get_env("MUMBLE_HOST") || "localhost"
mumble_port = (System.get_env("MUMBLE_PORT") || "64738") |> String.to_integer()
mumble_username = System.get_env("MUMBLE_USERNAME") || "MusicBot"

# Ensure necessary directories exist
File.mkdir_p!("/tmp/test_audio")
File.mkdir_p!("/tmp/downloads")
File.mkdir_p!("/tmp/mumble_chat/opus_encoded")

# Download a test file if one doesn't exist yet
test_download = "/tmp/test_audio/test_music.mp3"
unless File.exists?(test_download) do
  IO.puts("Downloading test audio file...")
  cmd = "curl -L '#{test_audio_url}' -o #{test_download}"
  System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
  IO.puts("Downloaded test file to: #{test_download}")
end

# Start the Mumble application
Application.ensure_all_started(:mumble_chat)

# Wait for connection to establish
IO.puts("\nConnecting to Mumble server at #{mumble_host}:#{mumble_port} as #{mumble_username}...")
Process.sleep(3000)  # Wait 3 seconds for connection

# Now let's test encoding the file and playing it
IO.puts("\nEncoding file to Opus format...")
case AudioEncoder.encode_to_opus(test_download) do
  {:ok, opus_file} ->
    IO.puts("✅ Successfully encoded file to: #{opus_file}")

    # Now try to play it through Mumble
    IO.puts("\nPlaying encoded audio through Mumble...")
    IO.puts("(You should hear music in your Mumble client)")

    # Wait a moment to ensure we're connected
    Process.sleep(1000)

    # Play the file using the PlaybackController
    MumbleChat.PlaybackController.play(opus_file)

    # Keep the script running
    IO.puts("\nAudio playback initiated. Press Enter to stop playback.")
    IO.gets("")

    # Stop playback
    MumbleChat.PlaybackController.stop()

  {:error, reason} ->
    IO.puts("❌ Error encoding file: #{inspect(reason)}")
end

IO.puts("\nTest completed! Ctrl+C to exit.")
:timer.sleep(:infinity)
