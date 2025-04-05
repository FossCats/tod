defmodule MumbleChat.AudioStreamingTest do
  use ExUnit.Case
  
  @moduletag :integration
  
  # This is an integration test that requires a running Mumble server
  # and an OPUS file to test with. It's meant to be run manually.
  
  @tag :manual
  test "stream_opus_file sends audio data through UDP tunnel" do
    # Path to a test OPUS file - replace with an actual file for testing
    test_file = System.get_env("TEST_OPUS_FILE")
    
    if test_file && File.exists?(test_file) do
      # Start the application
      Application.ensure_all_started(:mumble_chat)
      
      # Wait for connection
      Process.sleep(2000)
      
      # Stream the file
      MumbleChat.Client.stream_opus_file(test_file)
      
      # This test doesn't actually assert anything - it's meant to be
      # manually verified by listening to the audio on the Mumble server
      assert true
    else
      IO.puts """
      Skipping test: No test OPUS file available.
      To run this test, set the TEST_OPUS_FILE environment variable:
      
      TEST_OPUS_FILE=/path/to/test.opus mix test test/audio_streaming_test.exs
      """
      
      # Skip the test
      assert true
    end
  end
  
  @tag :manual
  test "stream_opus_file handles non-existent files" do
    # Try to stream a non-existent file
    non_existent_file = "/path/to/non-existent/file.opus"
    
    # Start the application
    Application.ensure_all_started(:mumble_chat)
    
    # Wait for connection
    Process.sleep(2000)
    
    # This should log an error but not crash
    MumbleChat.Client.stream_opus_file(non_existent_file)
    
    # Wait a bit to ensure the error is logged
    Process.sleep(500)
    
    # If we got here without crashing, the test passes
    assert true
  end
end
