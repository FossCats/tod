#!/usr/bin/env elixir

# Example script to demonstrate streaming an OPUS file to a Mumble server
# Usage: elixir stream_opus.exs /path/to/your/audio.opus [target]

# Start the application
Application.ensure_all_started(:mumble_chat)

# Get command line arguments
args = System.argv()

case args do
  [file_path | rest] ->
    # Check if the file exists
    if File.exists?(file_path) do
      # Get target from arguments or use default (0)
      target = 
        case rest do
          [target_str | _] ->
            case Integer.parse(target_str) do
              {target, _} when target >= 0 and target <= 31 -> target
              _ -> 
                IO.puts("Invalid target value. Using default (0).")
                0
            end
          [] -> 0
        end
      
      # Wait for the client to connect
      IO.puts("Waiting for connection to Mumble server...")
      Process.sleep(2000)
      
      # Stream the OPUS file
      IO.puts("Streaming OPUS file: #{file_path} with target: #{target}")
      MumbleChat.Client.stream_opus_file(file_path, target)
      
      # Keep the script running until streaming is complete
      # This is a simple approach - in a real application you might want to use
      # a more sophisticated mechanism to track when streaming is complete
      IO.puts("Streaming started. Press Ctrl+C to exit.")
      Process.sleep(:infinity)
    else
      IO.puts("Error: File not found: #{file_path}")
      System.halt(1)
    end
    
  [] ->
    IO.puts("Usage: elixir stream_opus.exs /path/to/your/audio.opus [target]")
    IO.puts("  target: Optional target value (0-31), defaults to 0")
    System.halt(1)
end
