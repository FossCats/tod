defmodule MumbleChat.Audio do
  @moduledoc """
  Audio functionality for the Mumble client.

  This module provides functionality to handle audio streaming,
  sequence tracking, and audio packet creation for the Mumble protocol.
  """

  require Logger
  import Bitwise

  # Message types
  @udp_tunnel_type 1
  @audio_type_opus 4

  # Audio packet configuration
  # Maximum audio packet size (1020 bytes as per Mumble spec)
  @max_audio_packet_size 1020
  # Chunk size for reading audio files (slightly smaller than max to allow for header)
  @chunk_size 1000

  # Audio timing constants (in milliseconds)
  # Each sequence number represents 10ms of audio
  @sequence_duration 10
  # Reset sequence after 5 seconds of silence
  @sequence_reset_interval 5000
  # Amount of audio time per packet (20ms)
  @audio_per_packet 20
  # Sample rate for Opus audio (48kHz)
  @sample_rate 48000

  @doc """
  Streams audio data from an OPUS file to the Mumble server through the TCP connection
  using the UDP tunnel.

  ## Parameters

  - `socket`: SSL socket connection to the Mumble server
  - `file_path`: Path to the OPUS audio file
  - `target`: Target for the audio packet (5 bits, default 0)
  """
  def stream_file_data(socket, file_path, target) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        # Initialize audio stream state
        state = %{
          file: file,
          socket: socket,
          target: target,
          sequence: 0,
          sequence_start_time: System.system_time(:millisecond),
          sequence_last_time: System.system_time(:millisecond)
        }

        # Start the streaming loop
        stream_loop_with_timing(state)

        # Clean up when done
        File.close(file)
        Logger.info("Finished streaming OPUS file: #{file_path}")

      {:error, reason} ->
        Logger.error("Failed to open OPUS file: #{inspect(reason)}")
    end
  end

  @doc """
  Sends data through the UDP tunnel (message type 1).

  This function ensures the packet doesn't exceed the maximum size
  and sends it through the established socket connection.

  ## Parameters

  - `socket`: SSL socket connection to the Mumble server
  - `packet`: Audio packet data to send
  """
  def send_udp_tunnel(socket, packet) do
    # Ensure packet size doesn't exceed maximum
    if byte_size(packet) <= @max_audio_packet_size do
      send_message(socket, @udp_tunnel_type, packet)
    else
      Logger.warning("Audio packet exceeds maximum size and was truncated")
      # Truncate packet to maximum size
      truncated = binary_part(packet, 0, @max_audio_packet_size)
      send_message(socket, @udp_tunnel_type, truncated)
    end
  end

  @doc """
  Creates an audio packet with the appropriate header and sequence number.

  ## Parameters

  - `data`: The audio data to send
  - `target`: Target for the audio packet (5 bits, 0-31)
  - `sequence`: Sequence number for the audio packet

  ## Returns

  A binary containing the formatted audio packet with header, sequence, and data.
  """
  def create_audio_packet_with_sequence(data, target, sequence) do
    # Create header: type (4 for OPUS) in 3 most significant bits + target in 5 least significant bits
    header = bor(bsl(@audio_type_opus, 5), band(target, 0x1F))

    # Encode sequence as VarInt
    sequence_bytes = encode_varint(sequence)

    # Combine header, sequence, and audio data
    <<header::size(8), sequence_bytes::binary, data::binary>>
  end

  @doc """
  Calculate the next sequence number and timing values for audio packets.

  ## Parameters

  - `sequence`: Current sequence number
  - `start_time`: Time when the audio sequence started (in milliseconds)
  - `last_time`: Time of the last sent audio packet (in milliseconds)
  - `current_time`: Current system time (in milliseconds)

  ## Returns

  A tuple containing `{new_sequence, new_last_time, new_start_time}`.
  """
  def calculate_sequence_and_timing(sequence, start_time, last_time, current_time) do
    # Log the current timing values for debugging
    Logger.debug(
      "Timing calculation: seq=#{sequence}, start=#{start_time}, last=#{last_time}, current=#{current_time}"
    )

    cond do
      # If we've waited too long, reset the sequence
      last_time + @sequence_reset_interval <= current_time ->
        Logger.debug("Resetting sequence due to long pause (> #{@sequence_reset_interval}ms)")
        {0, current_time, current_time}

      # If there's been a significant pause, recalculate sequence based on elapsed time
      last_time + @audio_per_packet * 2 <= current_time ->
        # Calculate new sequence based on elapsed time since start
        elapsed_ms = current_time - start_time
        new_sequence = div(elapsed_ms, @sequence_duration)
        new_last_time = start_time + new_sequence * @sequence_duration

        # Log the new values
        Logger.debug(
          "Recalculating sequence after pause: new_seq=#{new_sequence} (elapsed=#{elapsed_ms}ms)"
        )

        {new_sequence, new_last_time, start_time}

      # For continuous audio, just increment by the packet duration
      true ->
        # For continuous streaming, increment by fixed amount
        frames_per_packet = div(@audio_per_packet, @sequence_duration)
        new_sequence = sequence + frames_per_packet
        new_last_time = start_time + new_sequence * @sequence_duration

        # Log the incremented sequence
        Logger.debug(
          "Incrementing sequence: #{sequence} -> #{new_sequence} (+#{frames_per_packet})"
        )

        {new_sequence, new_last_time, start_time}
    end
  end

  @doc """
  Returns the audio packet duration in milliseconds.
  Used by other modules to calculate proper audio timing.
  """
  def audio_per_packet, do: @audio_per_packet

  @doc """
  Returns the sequence duration in milliseconds.
  Used by other modules to calculate proper audio timing.
  """
  def sequence_duration, do: @sequence_duration

  @doc """
  Returns the sequence reset interval in milliseconds.
  Used by other modules to determine when to reset audio sequencing.
  """
  def sequence_reset_interval, do: @sequence_reset_interval

  # Stream audio with proper timing and sequence tracking
  defp stream_loop_with_timing(state) do
    current_time = System.system_time(:millisecond)

    # Check if we should send a packet now
    if state.sequence_last_time + @audio_per_packet <= current_time do
      # Read a chunk of audio data
      case IO.binread(state.file, @chunk_size) do
        data when is_binary(data) and byte_size(data) > 0 ->
          # Calculate new sequence value and timing
          {new_sequence, new_last_time, new_start_time} =
            calculate_sequence_and_timing(
              state.sequence,
              state.sequence_start_time,
              state.sequence_last_time,
              current_time
            )

          # Create and send the audio packet with proper sequence number
          packet = create_audio_packet_with_sequence(data, state.target, new_sequence)
          send_udp_tunnel(state.socket, packet)

          # Log for debugging
          Logger.debug(
            "Sending audio packet with sequence #{new_sequence} at time #{current_time}"
          )

          # Update state for next iteration
          new_state = %{
            state
            | sequence: new_sequence,
              sequence_last_time: new_last_time,
              sequence_start_time: new_start_time
          }

          # Add a small delay before checking again, but less than our packet interval
          Process.sleep(5)

          # Continue streaming
          stream_loop_with_timing(new_state)

        _ ->
          # End of file or error
          :ok
      end
    else
      # Not time to send a packet yet, wait a bit and check again
      Process.sleep(5)
      stream_loop_with_timing(state)
    end
  end

  # Simple VarInt encoding for sequence numbers
  defp encode_varint(value) when value < 0x80 do
    # For small values (0-127), use a single byte with MSB=0
    <<value::size(8)>>
  end

  defp encode_varint(value) when value < 0x4000 do
    # For medium values (128-16383), use two bytes with proper VarInt encoding
    # First byte: MSB=1, followed by 7 lower bits of value
    # Second byte: MSB=0, followed by the next 7 bits of value
    # Set MSB and use 7 LSBs
    byte1 = 0x80 ||| (value &&& 0x7F)
    # Next 7 bits with MSB=0
    byte2 = value >>> 7 &&& 0x7F
    <<byte1::size(8), byte2::size(8)>>
  end

  defp encode_varint(value) when value < 0x200000 do
    # For larger values (16384-2097151), use three bytes
    # Set MSB and use 7 LSBs
    byte1 = 0x80 ||| (value &&& 0x7F)
    # Set MSB and use next 7 bits
    byte2 = 0x80 ||| (value >>> 7 &&& 0x7F)
    # Final 7 bits with MSB=0
    byte3 = value >>> 14 &&& 0x7F
    <<byte1::size(8), byte2::size(8), byte3::size(8)>>
  end

  defp encode_varint(value) do
    # For very large values, use four bytes
    # Set MSB and use 7 LSBs
    byte1 = 0x80 ||| (value &&& 0x7F)
    # Set MSB and use next 7 bits
    byte2 = 0x80 ||| (value >>> 7 &&& 0x7F)
    # Set MSB and use next 7 bits
    byte3 = 0x80 ||| (value >>> 14 &&& 0x7F)
    # Final 7 bits with MSB=0
    byte4 = value >>> 21 &&& 0x7F
    <<byte1::size(8), byte2::size(8), byte3::size(8), byte4::size(8)>>
  end

  # Extract sequence number from packet for debugging
  defp extract_sequence(packet) do
    case packet do
      # Single byte sequence (0-127)
      <<_header::size(8), seq::size(8), _rest::binary>> when (seq &&& 0x80) == 0 ->
        {:ok, seq}

      # Two byte sequence (128-16383)
      <<_header::size(8), byte1::size(8), byte2::size(8), _rest::binary>>
      when (byte1 &&& 0x80) != 0 and (byte2 &&& 0x80) == 0 ->
        value = (byte1 &&& 0x7F) ||| (byte2 &&& 0x7F) <<< 7
        {:ok, value}

      # Three byte sequence (16384-2097151)
      <<_header::size(8), byte1::size(8), byte2::size(8), byte3::size(8), _rest::binary>>
      when (byte1 &&& 0x80) != 0 and (byte2 &&& 0x80) != 0 and (byte3 &&& 0x80) == 0 ->
        value = (byte1 &&& 0x7F) ||| (byte2 &&& 0x7F) <<< 7 ||| (byte3 &&& 0x7F) <<< 14
        {:ok, value}

      # Unknown format
      _ ->
        :error
    end
  end

  # Utility function to send messages to the server - needed for UDP tunnel
  defp send_message(socket, message_type, message_data) do
    header = <<message_type::size(16), byte_size(message_data)::size(32)>>
    Logger.debug("Sending message type: #{message_type}, length: #{byte_size(message_data)}")

    result = :ssl.send(socket, [header, message_data])

    case result do
      :ok ->
        Logger.debug("Message sent successfully")
        :ok

      error ->
        Logger.error("Failed to send message: #{inspect(error)}")
        error
    end
  end
end
