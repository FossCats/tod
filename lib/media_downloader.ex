defmodule MediaDownloader do
  def download_audio(url, max_size_bytes) do
    with {:ok, validated_url} <- validate_url(url),
         {:ok, file_path} <- run_yt_dlp(validated_url),
         {:ok, _} <- validate_file_size(file_path, max_size_bytes) do
      {:ok, file_path}
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
    output_path = "/tmp/downloads/#{:crypto.strong_rand_bytes(16) |> Base.url_encode64()}.opus"
    
    cmd = "yt-dlp -x --audio-format opus -f bestaudio/best -o '#{output_path}' '#{url}'"
    
    case System.cmd("sh", ["-c", cmd]) do
      {_, 0} -> {:ok, output_path}
      {error_output, _} -> {:error, {:yt_dlp_error, error_output}}
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
end
