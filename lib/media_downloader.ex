defmodule MediaDownloader do
  require Logger

  @doc """
  Downloads audio from a URL and ensures it's in Opus format.
  Returns either:
    - {:ok, file_path} with the path to the converted Opus file
    - {:error, reason} on failure
  """
  def download_audio(url, max_size_bytes) do
    with {:ok, validated_url} <- validate_url(url),
         {:ok, file_path} <- run_yt_dlp(validated_url),
         {:ok, _} <- validate_file_size(file_path, max_size_bytes),
         {:ok, opus_file} <- ensure_opus_format(file_path) do
      {:ok, opus_file}
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

  defp run_yt_dlp(url) do
    # Create the downloads directory if it doesn't exist
    downloads_dir = "/tmp/downloads"
    File.mkdir_p!(downloads_dir)

    # Generate a unique output filename
    output_path = "#{downloads_dir}/#{:crypto.strong_rand_bytes(8) |> Base.url_encode64()}"

    # We'll download in the best audio format and convert later if needed
    # This is more flexible than forcing Opus at download time
    cmd = "yt-dlp -x --audio-format best -f bestaudio/best -o '#{output_path}.%(ext)s' '#{url}'"
    Logger.debug("Running yt-dlp command: #{cmd}")

    case System.cmd("sh", ["-c", cmd]) do
      {output, 0} ->
        # yt-dlp adds the extension automatically, we need to find the file
        case find_downloaded_file(downloads_dir, output_path) do
          {:ok, file_path} ->
            Logger.info("Successfully downloaded file to: #{file_path}")
            {:ok, file_path}

          {:error, reason} ->
            Logger.error("Failed to locate downloaded file: #{reason}")
            {:error, {:yt_dlp_error, "Failed to locate downloaded file"}}
        end

      {error_output, _} ->
        Logger.error("yt-dlp error: #{error_output}")
        {:error, {:yt_dlp_error, error_output}}
    end
  end

  # Find the file that yt-dlp downloaded (since it adds the extension automatically)
  defp find_downloaded_file(dir, base_path) do
    # List all files in the directory
    case File.ls(dir) do
      {:ok, files} ->
        # Get just the base filename without path
        base_name = Path.basename(base_path)

        # Find files that start with our base path
        matching_files =
          Enum.filter(files, fn file ->
            String.starts_with?(file, base_name)
          end)

        case matching_files do
          [file | _] -> {:ok, Path.join(dir, file)}
          [] -> {:error, :file_not_found}
        end

      {:error, reason} ->
        {:error, reason}
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

  @doc """
  Ensures the file is in Opus format, converting it if necessary.
  """
  def ensure_opus_format(file_path) do
    extension = Path.extname(file_path) |> String.downcase()

    if extension == ".opus" do
      # Already in Opus format
      Logger.info("File is already in Opus format: #{file_path}")
      {:ok, file_path}
    else
      # Need to convert to Opus
      Logger.info("Converting file to Opus format: #{file_path}")
      AudioEncoder.encode_to_opus(file_path)
    end
  end
end
