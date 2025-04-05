defmodule Mix.Tasks.Protox.Gen do
  use Mix.Task

  @shortdoc "Generates Elixir modules from proto files"
  def run(_) do
    Mix.shell().info("Generating protobuf modules...")
    System.cmd("protoxc", ["-i", "priv", "-o", "lib/generated", "priv/Mumble.proto"])
    Mix.shell().info("Done.")
  end
end
