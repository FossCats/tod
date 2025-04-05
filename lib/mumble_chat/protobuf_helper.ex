defmodule MumbleChat.ProtobufHelper do
  require Logger
  import Bitwise

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
      10,
      byte_size(username_bytes),
      username_bytes::binary,
      # password field (2)
      18,
      byte_size(password_bytes),
      password_bytes::binary,
      # opus field (5) - true
      40,
      1
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

  def create_text_message(message, channel_id, session_id \\ nil) do
    # Format based on the Mumble protocol
    message_bytes = :binary.list_to_bin(String.to_charlist(message))

    Logger.debug(
      "Creating text message: '#{message}', channel_id: #{inspect(channel_id)}, session_id: #{inspect(session_id)}"
    )

    # Start with message field
    message_data = <<
      # Field 5: message (required string)
      42,
      byte_size(message_bytes),
      message_bytes::binary
    >>

    # Add actor field (our session ID) if we have one
    message_data =
      if session_id do
        # Field 1: actor (uint32) - encoded as a varint
        # (field_number << 3) | wire_type = (1 << 3) | 0 = 8
        tag = 8
        encoded_session_id = encode_varint(session_id)
        <<tag>> <> encoded_session_id <> message_data
      else
        message_data
      end

    # Add channel_id if provided
    message_data =
      if channel_id do
        # Field 3: channel_id (repeated uint32)
        # For TextMessage, channel_id is a repeated field using the LENGTH_DELIMITED wire type (2)
        # (field_number << 3) | wire_type = (3 << 3) | 2 = 26
        tag = 26

        # We'll encode a single channel ID as a packed repeated field
        # First, encode the channel ID as a varint
        encoded_channel_id = encode_varint(channel_id)

        # Length of the encoded channel ID
        length = byte_size(encoded_channel_id)

        # Append to the message data
        message_data <> <<tag, length>> <> encoded_channel_id
      else
        message_data
      end

    Logger.debug(
      "Final message data (#{byte_size(message_data)} bytes): #{inspect(message_data, limit: 30)}"
    )

    message_data
  end

  # Encode an integer as a varint (variable length integer)
  defp encode_varint(value) when value < 128 do
    <<value>>
  end

  defp encode_varint(value) do
    # Get the 7 least significant bits and set the MSB to 1
    first_byte = bor(band(value, 0x7F), 0x80)
    # Encode the rest of the value (shifted right by 7 bits)
    rest = encode_varint(bsr(value, 7))
    <<first_byte>> <> rest
  end

  # Decode a ServerSync message to get session ID and other info
  def decode_server_sync(data) do
    try do
      # Parse field 1 (session) - field ID 8 followed by the session ID
      case :binary.match(data, <<8>>) do
        {pos, 1} ->
          rest_data = binary_part(data, pos + 1, byte_size(data) - (pos + 1))
          {session_id, rest} = decode_varint(rest_data)

          Logger.debug("Decoded session_id=#{session_id} from ServerSync")

          # Try to extract max_bandwidth (field 2, ID 16)
          max_bandwidth =
            case :binary.match(rest, <<16>>) do
              {bw_pos, 1} ->
                bw_rest = binary_part(rest, bw_pos + 1, byte_size(rest) - (bw_pos + 1))
                {bandwidth, _} = decode_varint(bw_rest)
                bandwidth

              _ ->
                nil
            end

          # Try to extract welcome_text (field 3, ID 26)
          welcome_text =
            case :binary.match(rest, <<26>>) do
              {text_pos, 1} ->
                text_rest = binary_part(rest, text_pos + 1, byte_size(rest) - (text_pos + 1))
                <<text_len, text::binary-size(text_len), _::binary>> = text_rest
                text

              _ ->
                nil
            end

          # Try to extract permissions (field 4, ID 32)
          permissions =
            case :binary.match(rest, <<32>>) do
              {perm_pos, 1} ->
                perm_rest = binary_part(rest, perm_pos + 1, byte_size(rest) - (perm_pos + 1))
                {perms, _} = decode_varint(perm_rest)
                perms

              _ ->
                nil
            end

          %{
            session_id: session_id,
            max_bandwidth: max_bandwidth,
            welcome_text: welcome_text,
            permissions: permissions
          }

        _ ->
          Logger.warning("Could not find session ID field in ServerSync message")
          %{session_id: nil}
      end
    rescue
      e ->
        Logger.error("Error decoding ServerSync message: #{inspect(e)}")
        %{session_id: nil}
    end
  end

  # Decode a UserState message to extract user information
  def decode_user_state(data) do
    try do
      # Create a map to store extracted fields
      user_state = %{}

      # Try to extract session ID (field 1, ID 8)
      user_state =
        case :binary.match(data, <<8>>) do
          {pos, 1} ->
            # The byte following the tag could be a varint
            # In protobuf, small integers (< 128) are encoded as single bytes
            rest_data = binary_part(data, pos + 1, byte_size(data) - (pos + 1))
            {session_id, _} = decode_varint(rest_data)

            Logger.debug("Decoded session_id=#{session_id} from UserState")
            Map.put(user_state, :session_id, session_id)

          _ ->
            user_state
        end

      # Try to extract actor (field 2, ID 16)
      user_state =
        case :binary.match(data, <<16>>) do
          {pos, 1} ->
            rest_data = binary_part(data, pos + 1, byte_size(data) - (pos + 1))
            {actor, _} = decode_varint(rest_data)

            Logger.debug("Decoded actor=#{actor} from UserState")
            Map.put(user_state, :actor, actor)

          _ ->
            user_state
        end

      # Try to extract name (field 3, ID 26)
      user_state =
        case :binary.match(data, <<26>>) do
          {pos, 1} ->
            # After tag 26, we have a length byte followed by the string
            <<_::binary-size(pos + 1), name_len, name::binary-size(name_len), _::binary>> = data

            Logger.debug("Decoded name='#{name}' from UserState")
            Map.put(user_state, :name, name)

          _ ->
            user_state
        end

      # Try to extract channel_id (field 5, ID 40)
      user_state =
        case :binary.match(data, <<40>>) do
          {pos, 1} ->
            rest_data = binary_part(data, pos + 1, byte_size(data) - (pos + 1))
            {channel_id, _} = decode_varint(rest_data)

            Logger.debug("Decoded channel_id=#{channel_id} from UserState")
            Map.put(user_state, :channel_id, channel_id)

          _ ->
            user_state
        end

      user_state
    rescue
      e ->
        Logger.error("Error decoding UserState message: #{inspect(e)}")
        %{}
    end
  end

  # Helper function to decode a varint (variable length integer)
  # Google Protocol Buffers use this encoding for integers
  defp decode_varint(<<byte::8, rest::binary>>) do
    # Check if the MSB is set (means we need to continue reading)
    if Bitwise.band(byte, 0x80) == 0 do
      # Simple case: single byte integer
      {byte, rest}
    else
      # Complex case: multi-byte integer
      # Remove the MSB and shift left 7 bits
      value = Bitwise.band(byte, 0x7F)
      {next_value, next_rest} = decode_varint(rest)
      {Bitwise.bor(value, Bitwise.bsl(next_value, 7)), next_rest}
    end
  end

  defp decode_varint(<<>>) do
    {0, <<>>}
  end

  # Send to current channel
  def send_message(message) do
    MumbleChat.Client.send_message(message)
  end

  # Send to specific channel
  def send_message(message, channel_id) do
    MumbleChat.Client.send_message(message, channel_id)
  end
end
