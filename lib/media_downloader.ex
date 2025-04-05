defmodule MediaDownloader do
  require Logger

  @download_dir "/tmp/downloads"
  @opus_dir "/tmp/mumble_chat/opus_encoded"

  def download_audio(url, max_size_bytes) do
    with {:ok, validated_url} <- validate_url(url),
         :ok <- ensure_directories(),
         {:ok, wav_path} <- run_yt_dlp(validated_url),
         {:ok, _} <- validate_file_size(wav_path, max_size_bytes),
         {:ok, opus_path} <- convert_to_opus(wav_path) do
      {:ok, opus_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, url}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp ensure_directories do
    case File.mkdir_p(@download_dir) do
      :ok ->
        case File.mkdir_p(@opus_dir) do
          :ok -> :ok
          {:error, :eexist} -> :ok
          {:error, reason} -> {:error, {:mkdir_error, "opus_dir: #{reason}"}}
        end

      {:error, :eexist} ->
        case File.mkdir_p(@opus_dir) do
          :ok -> :ok
          {:error, :eexist} -> :ok
          {:error, reason} -> {:error, {:mkdir_error, "opus_dir: #{reason}"}}
        end

      {:error, reason} ->
        {:error, {:mkdir_error, "download_dir: #{reason}"}}
    end
  end

  defp run_yt_dlp(url) do
    filename = :crypto.strong_rand_bytes(16) |> Base.url_encode64()
    output_path = Path.join(@download_dir, "#{filename}.wav")

    cmd =
      "yt-dlp -x --audio-format wav --audio-quality 0 " <>
        "--postprocessor-args \"-ar 48000 -ac 1 -acodec pcm_s16le\" " <>
        "-o '#{output_path}' '#{url}' 2>&1"

    Logger.info("Downloading audio with yt-dlp: #{url}")

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {output, 0} ->
        # Log the successful output
        Logger.debug("yt-dlp successful output: #{String.slice(output, 0, 500)}")

        # Check if the file was actually created
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          # Sometimes yt-dlp adds extensions like .wav.wav, try to find the file
          case File.ls(@download_dir) do
            {:ok, files} ->
              case Enum.find(files, fn f -> String.starts_with?(f, filename) end) do
                nil ->
                  Logger.error("Downloaded file not found. yt-dlp output: #{output}")

                  {:error,
                   {:file_not_found, "Downloaded file not found. Check logs for details."}}

                found ->
                  full_path = Path.join(@download_dir, found)
                  Logger.info("Found downloaded file at alternate path: #{full_path}")
                  {:ok, full_path}
              end

            {:error, reason} ->
              Logger.error("Failed to list download directory: #{inspect(reason)}")
              {:error, {:file_not_found, reason}}
          end
        end

      {error_output, exit_code} ->
        Logger.error("yt-dlp failed with exit code #{exit_code}: #{error_output}")
        {:error, {:yt_dlp_error, String.trim(error_output)}}
    end
  end

  defp validate_file_size(file_path, max_size_bytes) do
    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} when size <= max_size_bytes ->
        {:ok, file_path}

      {:ok, %File.Stat{size: size}} ->
        File.rm!(file_path)
        {:error, {:file_too_large, size, max_size_bytes}}

      {:error, reason} ->
        {:error, {:file_stat_error, reason}}
    end
  end

  defp convert_to_opus(wav_path) do
    # Generate a filename for the opus file
    filename = Path.basename(wav_path, Path.extname(wav_path))
    opus_path = Path.join(@opus_dir, "#{filename}.opus")

    # Use the AudioEncoder to convert the file
    Logger.info("Converting WAV to Opus: #{wav_path} -> #{opus_path}")

    case AudioEncoder.encode_to_opus(wav_path, opus_path) do
      {:ok, output_path} ->
        # Optionally clean up the WAV file to save space
        File.rm(wav_path)
        {:ok, output_path}

      {:error, reason} ->
        {:error, {:opus_conversion_error, reason}}
    end
  end
end
