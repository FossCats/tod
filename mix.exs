defmodule MumbleChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :mumble_chat,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {MumbleChat.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Keep both libraries
      # Original protobuf library
      {:protobuf, "~> 0.8.0"},
      # Alternative protobuf library
      {:protox, "~> 1.6"},
      # SSL verification
      {:ssl_verify_fun, "~> 1.1"},
      # JSON handling
      {:jason, "~> 1.2"},
      # Opus encoding functionality
      {:membrane_opus_plugin, "~> 0.20.5"},
      # Audio conversion with FFmpeg SWResample
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.2"},
      # File plugin for reading/writing files
      {:membrane_file_plugin, "~> 0.16.0"},
      # Core Membrane dependencies
      {:membrane_core, "~> 1.0"}
    ]
  end
end
