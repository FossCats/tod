defmodule UrlExtractionTest do
  use ExUnit.Case
  
  # This is a simplified version of the extract_url_from_html function
  # from MumbleChat.Client for testing purposes
  def extract_url_from_html(text) do
    cond do
      # Case 1: Text contains an <a> tag with href attribute
      String.contains?(text, "<a href=") ->
        # Extract the URL from the href attribute
        case Regex.run(~r/<a href="([^"]+)"/, text, capture: :all_but_first) do
          [url] -> url
          _ -> text # Fallback to original text if regex doesn't match
        end
      
      # Case 2: No HTML formatting, return the text as is
      true -> text
    end
  end
  
  test "extracts URL from HTML a tag" do
    html_text = "<a href=\"https://example.com\">Example Website</a>"
    assert extract_url_from_html(html_text) == "https://example.com"
  end
  
  test "returns plain URL as is" do
    plain_url = "https://example.com"
    assert extract_url_from_html(plain_url) == "https://example.com"
  end
  
  test "handles !play command with HTML URL" do
    command = "!play <a href=\"https://youtube.com/watch?v=12345\">YouTube Video</a>"
    url_part = String.trim_leading(command, "!play ")
    assert extract_url_from_html(url_part) == "https://youtube.com/watch?v=12345"
  end
end
