defmodule AudioEncoder do
  @moduledoc """
  Encodes audio files to Opus format using the Membrane Framework with FFmpeg SWResample.
  This module is used to convert audio files to the format expected by the Mumble client.
  """
  use Membrane.Pipeline
  require Logger

  alias Membrane.RawAudio
  alias Membrane.FFmpeg.SWResample.Converter
  alias Membrane.File
  alias Membrane.Opus

  @doc """
  Encodes an audio file to OPUS format for streaming to Mumble

  ## Parameters
    - input_file: Path to the input audio file (any format that ffmpeg can handle)
    - output_file: Path where the output OPUS file will be saved

  ## Returns
    - {:ok, output_file} on success
    - {:error, reason} on failure
  """
  def encode_to_opus(input_file, output_file \\ nil) do
    # Generate output file path if not provided
    output_file = output_file || generate_output_path(input_file)

    # Ensure output directory exists
    File.mkdir_p!(Path.dirname(output_file))

    # Check if the file is already in Opus format
    if Path.extname(input_file) |> String.downcase() == ".opus" do
      # If already opus, just copy the file to preserve the output path consistency
      Logger.info("File already in Opus format: #{input_file}, copying to #{output_file}")
      File.cp!(input_file, output_file)
      {:ok, output_file}
    else
      # Fall back to direct FFmpeg command for conversion when input is not opus
      Logger.info("Converting to Opus format using FFmpeg: #{input_file}")

      # Build the FFmpeg command for conversion
      cmd =
        "ffmpeg -i \"#{input_file}\" -c:a libopus -b:a 64k -vbr on -application voip -ac 1 -ar 48000 \"#{output_file}\" -y"

      # Execute the command
      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
        {_output, 0} ->
          # Command succeeded, check if the file exists
          if File.exists?(output_file) do
            {:ok, output_file}
          else
            {:error, :output_file_not_created}
          end

        {error_output, _exit_code} ->
          Logger.error("FFmpeg encoding failed: #{error_output}")
          {:error, {:ffmpeg_error, error_output}}
      end
    end
  end

  # Generate an output file path based on the input path
  defp generate_output_path(input_file) do
    # Create a temporary directory if it doesn't exist
    tmp_dir = "/tmp/mumble_chat/opus_encoded"
    File.mkdir_p!(tmp_dir)

    # Generate a unique filename
    basename = Path.basename(input_file, Path.extname(input_file))
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64()

    Path.join(tmp_dir, "#{basename}_#{random_suffix}.opus")
  end
end
