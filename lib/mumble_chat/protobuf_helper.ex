defmodule MumbleChat.ProtobufHelper do
  # Simple authentication message creator
  def create_authenticate(username, password, _opus) do
    # Format based on the Mumble protocol
    username_bytes = :binary.list_to_bin(String.to_charlist(username))
    password_bytes = :binary.list_to_bin(String.to_charlist(password))

    # Field 1: username (string)
    # Field 2: password (string)
    # Field 5: opus (bool)
    <<
      # username field (1)
      10, byte_size(username_bytes), username_bytes::binary,
      # password field (2)
      18, byte_size(password_bytes), password_bytes::binary,
      # opus field (5) - true
      40, 1
    >>
  end

  # Simple ping message creator
  def create_ping(timestamp) do
    # Field 1: timestamp (uint64)
    <<8, timestamp::little-64>>
  end

  # Simple text message decoder
  def decode_text_message(data) do
    # Very basic parser - in real code you would need a proper protobuf decoder
    # This just extracts actor ID and message for demonstration
    case data do
      # Match common patterns in text messages
      <<8, actor::little-32, _rest::binary>> ->
        %{actor: actor, message: extract_message(data)}
      _ ->
        %{actor: 0, message: "Unable to parse message"}
    end
  end

  defp extract_message(data) do
    # Very simplified - looks for the message field (5)
    case :binary.match(data, <<42>>) do
      {pos, 1} ->
        length_pos = pos + 1
        <<_::binary-size(length_pos), len, message::binary-size(len), _::binary>> = data
        message
      _ ->
        "No message found"
    end
  end
end
