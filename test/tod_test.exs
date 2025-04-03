defmodule TodTest do
  use ExUnit.Case
  doctest Tod

  test "greets the world" do
    assert Tod.hello() == :world
  end
end
