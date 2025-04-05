defmodule AudioEncoder do
  @moduledoc """
  Audio encoder for converting various formats to Opus format
  for use with Mumble.

  This module uses FFmpeg directly for audio conversion.
  """
  require Logger

  @doc """
  Encodes an audio file to Opus format.

  ## Parameters

  - `input_path`: Path to the input audio file
  - `output_path`: Optional path for the output. If not provided, will append .opus to the input path.
  - `options`: Optional encoding options

  ## Options

  - `:bitrate`: Target bitrate in kbps (default: 64)
  - `:sample_rate`: Sample rate in Hz (default: 48000)
  - `:channels`: Number of audio channels (default: 1)
  - `:application`: Opus application type (default: "audio")

  ## Returns

  - `{:ok, opus_path}` on success
  - `{:error, reason}` on failure
  """
  def encode_to_opus(input_path, output_path \\ nil, options \\ []) do
    # Set default output path if not provided
    output = output_path || "#{input_path}.opus"

    # Extract options with defaults
    bitrate = Keyword.get(options, :bitrate, 64)
    sample_rate = Keyword.get(options, :sample_rate, 48000)
    channels = Keyword.get(options, :channels, 1)
    application = Keyword.get(options, :application, "audio")

    # Check if the input file exists
    if !File.exists?(input_path) do
      {:error, :input_file_not_found}
    else
      # Check if the file is already in Opus format
      if Path.extname(input_path) == ".opus" do
        Logger.info("File is already in Opus format: #{input_path}")
        {:ok, input_path}
      else
        # Ensure the output directory exists
        output_dir = Path.dirname(output)
        :ok = File.mkdir_p(output_dir)

        # Build the ffmpeg command
        ffmpeg_cmd = build_ffmpeg_command(input_path, output, bitrate, sample_rate, channels, application)

        # Execute the command
        Logger.info("Converting to Opus: #{input_path} -> #{output}")
        case System.cmd("sh", ["-c", ffmpeg_cmd], stderr_to_stdout: true) do
          {_, 0} ->
            Logger.info("Conversion successful")
            {:ok, output}

          {error, _} ->
            Logger.error("FFmpeg conversion error: #{error}")
            {:error, {:ffmpeg_error, error}}
        end
      end
    end
  end

  # Build the FFmpeg command with proper options
  defp build_ffmpeg_command(input, output, bitrate, sample_rate, channels, application) do
    "ffmpeg -y -i '#{input}' " <>
    "-c:a libopus " <>
    "-b:a #{bitrate}k " <>
    "-vbr on " <>
    "-compression_level 10 " <>
    "-application #{application} " <>
    "-ac #{channels} " <>
    "-ar #{sample_rate} " <>
    "'#{output}'"
  end
end
