#!/usr/bin/env elixir

# This script tests the AudioEncoder by encoding a sample audio file to Opus format

# First make sure directories for test files exist
File.mkdir_p!("/tmp/test_audio")

# Create a test WAV file using ffmpeg (1 second of silence)
test_wav = "/tmp/test_audio/test_silence.wav"
System.cmd("ffmpeg", ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "1", test_wav], stderr_to_stdout: true)
IO.puts("Created test WAV file: #{test_wav}")

# Load the required modules
Mix.install([
  {:membrane_opus_plugin, "~> 0.20.5"},
  {:membrane_core, "~> 1.0"}
])

# Add the current directory to the code path so we can find AudioEncoder
Code.prepend_path("./lib")

# Now try to load our AudioEncoder module
Code.require_file("lib/audio_encoder.ex")

# Try encoding the WAV file to Opus
IO.puts("\nAttempting to encode WAV to Opus...")
case AudioEncoder.encode_to_opus(test_wav) do
  {:ok, output_file} ->
    IO.puts("\n✅ Success! Encoded file saved to: #{output_file}")

    # Print file information
    {file_info, 0} = System.cmd("file", [output_file])
    IO.puts("\nFile info: #{file_info}")

    # Verify the file can be played
    IO.puts("\nPlaying the encoded file for verification (you should hear 1 second of silence):")
    System.cmd("ffplay", ["-nodisp", "-autoexit", output_file], stderr_to_stdout: true)

  {:error, reason} ->
    IO.puts("\n❌ Error encoding file: #{inspect(reason)}")
end

# Test cleanup
IO.puts("\nTest completed! Press Ctrl+C to exit.")
:timer.sleep(:infinity)
