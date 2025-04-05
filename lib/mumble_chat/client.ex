defmodule MumbleChat.Client do
  use GenServer
  require Logger
  import Bitwise

  @default_host "localhost"
  @default_port 64738
  @default_username "ElixirMumbleClient"
  @version_major 1
  @version_minor 3
  @version_patch 0

  # UDP Tunnel message type
  @udp_tunnel_type 1

  # Audio packet types
  @audio_type_opus 4

  # Maximum audio packet size (1020 bytes as per Mumble spec)
  @max_audio_packet_size 1020

  # Chunk size for reading audio files (slightly smaller than max to allow for header)
  @chunk_size 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Get configuration from environment or use defaults
    host = System.get_env("MUMBLE_HOST") || @default_host
    port = (System.get_env("MUMBLE_PORT") || @default_port) |> to_string() |> String.to_integer()
    username = System.get_env("MUMBLE_USERNAME") || @default_username

    # Connect to the Mumble server
    Logger.info("Connecting to Mumble server at #{host}:#{port} as #{username}")

    # Instead of immediately trying to connect, schedule a connection attempt
    # This allows the application to start even if the connection fails
    Process.send_after(self(), {:connect, host, port, username}, 100)

    # Start status timer
    status_timer = Process.send_after(self(), :log_status, 5000)

    # Return initial state without connection
    {:ok,
     %{
       socket: nil,
       ping_timer: nil,
       connect_attempts: 0,
       session_id: nil,
       current_channel_id: nil,
       status_timer: status_timer,
       buffer: <<>>
     }}
  end

  def handle_info({:connect, host, port, username}, state) do
    case connect(host, port, username) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        attempts = state.connect_attempts + 1

        if attempts < 5 do
          Logger.warning(
            "Connection attempt #{attempts} failed: #{inspect(reason)}. Retrying in #{attempts * 1000}ms..."
          )

          Process.send_after(self(), {:connect, host, port, username}, attempts * 1000)
          {:noreply, %{state | connect_attempts: attempts}}
        else
          Logger.error(
            "Failed to connect after #{attempts} attempts. Please check server availability."
          )

          {:noreply, state}
        end
    end
  end

  def connect(host, port, username) do
    # Find path to the certificates file
    cert_path = :code.priv_dir(:mumble_chat) ++ ~c"/cert.p12"

    Logger.info("Looking for certificate at: #{inspect(cert_path)}")

    # Try connecting without any certificate - simplest approach for initial testing
    ssl_options = [
      verify: :verify_none,
      active: true
    ]

    Logger.debug("Using SSL options: #{inspect(ssl_options)}")

    case :ssl.connect(String.to_charlist(host), port, ssl_options) do
      {:ok, socket} ->
        Logger.info("Connected to Mumble server successfully")

        # Send version information
        version = <<@version_major::size(16), @version_minor::size(8), @version_patch::size(8)>>
        result = send_message(socket, 0, version)
        Logger.info("Sent version message: #{inspect(result)}")

        # Send authentication (username, password, etc.)
        auth_data = MumbleChat.ProtobufHelper.create_authenticate(username, "", true)
        result = send_message(socket, 2, auth_data)
        Logger.info("Sent authentication message: #{inspect(result)}")

        # The server will now follow the Mumble connection sequence:
        # 1. CryptSetup (message type 15) - we'll respond in the handle_message function
        # 2. Channel states (message type 7)
        # 3. User states (message type 9)
        # 4. ServerSync (message type 5) - with our session ID

        # Create new state
        new_state = %{
          socket: socket,
          ping_timer: start_ping_timer(),
          connect_attempts: 0,
          session_id: nil,
          current_channel_id: nil,
          status_timer: Process.send_after(self(), :log_status, 5000),
          buffer: <<>>
        }

        {:ok, new_state}

      {:error, {:options, option_error}} ->
        Logger.error("SSL option error: #{inspect(option_error)}")
        {:stop, {:ssl_option_error, option_error}}

      {:error, reason} ->
        Logger.error("Failed to connect to Mumble server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle_info(:send_ping, %{socket: socket} = state) do
    ping_data = MumbleChat.ProtobufHelper.create_ping(System.system_time(:millisecond))
    send_message(socket, 3, ping_data)
    {:noreply, %{state | ping_timer: start_ping_timer()}}
  end

  def handle_info({:ssl, socket, data}, state) when is_list(data) do
    # Convert the received list of bytes to binary before processing
    binary_data = :erlang.list_to_binary(data)
    handle_info({:ssl, socket, binary_data}, state)
  end

  def handle_info({:ssl, socket, data}, %{buffer: buffer} = state) when is_binary(data) do
    # Append the new data to any existing buffer
    combined_data = buffer <> data

    # Process the combined data
    {new_state, remaining_data} = process_data(combined_data, state)

    # Keep any unprocessed data in the buffer
    {:noreply, %{new_state | buffer: remaining_data}}
  end

  # Handle case where we don't have a buffer in the state yet
  def handle_info({:ssl, socket, data}, state) when is_binary(data) do
    # Initialize buffer and delegate to the version with buffer
    handle_info({:ssl, socket, data}, Map.put(state, :buffer, <<>>))
  end

  # Helper function to process incoming data, potentially containing multiple messages
  defp process_data(data, state) do
    case data do
      # Check if we have at least a complete header (6 bytes: 2 for type, 4 for length)
      <<message_type::size(16), message_length::size(32), rest::binary>> = all_data ->
        # Check if we have the complete message
        if byte_size(rest) >= message_length do
          # Extract the message data
          <<message_data::binary-size(message_length), remaining::binary>> = rest

          # Log the received message
          Logger.info(
            "📩 Received message: type=#{message_type}, length=#{message_length}, data sample: #{inspect(binary_part(message_data, 0, min(16, byte_size(message_data))), limit: :infinity)}"
          )

          # Handle the message
          new_state = handle_message(message_type, message_data, state)

          # Process any remaining data recursively
          process_data(remaining, new_state)
        else
          # We don't have the complete message yet, return the current state and all data as buffer
          {state, all_data}
        end

      # Not enough data for a complete header, keep in buffer
      _ ->
        {state, data}
    end
  end

  def handle_info({:ssl_closed, _socket}, state) do
    Logger.error("SSL connection closed")
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _socket, reason}, state) do
    Logger.error("SSL error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(:log_status, state) do
    Logger.info(
      "💡 Connection Status: connected=#{state.socket != nil}, session_id=#{state.session_id || "none"}, channel_id=#{state.current_channel_id || "none"}"
    )

    # Reschedule the status report
    status_timer = Process.send_after(self(), :log_status, 5000)
    {:noreply, %{state | status_timer: status_timer}}
  end

  defp start_ping_timer do
    Process.send_after(self(), :send_ping, 15000)
  end

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

  defp handle_message(message_type, message_data, state) do
    case message_type do
      # Version = 0
      0 ->
        Logger.debug("Received Version message")
        state

      # UDPTunnel = 1
      1 ->
        Logger.debug("Received UDPTunnel message")
        state

      # Authenticate = 2
      2 ->
        Logger.debug("Received Authenticate message")
        state

      # Ping = 3
      3 ->
        Logger.debug("Received Ping message")
        state

      # Reject = 4
      4 ->
        Logger.debug("Received Reject message")
        state

      # ServerSync = 5
      5 ->
        Logger.info("Received ServerSync message")

        # Use the proper protobuf decoder
        case MumbleChat.ProtobufHelper.decode_server_sync(message_data) do
          %{session_id: session_id} when is_integer(session_id) ->
            Logger.info("🔑 Successfully authenticated - Got session ID: #{session_id}")

            # If we don't have a channel ID yet, let's join root channel (0) as a default
            new_state = %{state | session_id: session_id}

            if new_state.current_channel_id == nil do
              Logger.info("No channel ID set, defaulting to root channel (0)")
              %{new_state | current_channel_id: 0}
            else
              new_state
            end

          _ ->
            Logger.warning("Failed to extract session ID from ServerSync message")
            state
        end

      # ChannelRemove = 6
      6 ->
        Logger.info("Received ChannelRemove message")
        state

      # ChannelState = 7
      7 ->
        Logger.info("Received ChannelState message")

        # This message can contain channel information that might be useful
        # Try to extract channel ID
        case :binary.match(message_data, <<8>>) do
          {pos, 1} ->
            try do
              <<_::binary-size(pos + 1), channel_id::little-32, _rest::binary>> = message_data
              Logger.info("ChannelState has channel ID: #{channel_id}")
            rescue
              e -> Logger.error("Error extracting channel ID from ChannelState: #{inspect(e)}")
            end

          _ ->
            Logger.debug("No channel ID found in ChannelState message")
        end

        state

      # UserRemove = 8
      8 ->
        Logger.info("Received UserRemove message")

        # Try to extract the session ID from the message
        case :binary.match(message_data, <<8>>) do
          {pos, 1} ->
            try do
              <<_::binary-size(pos + 1), session_id::little-32, _rest::binary>> = message_data
              Logger.info("User removed with session ID: #{session_id}")
            rescue
              e -> Logger.error("Error extracting session ID from UserRemove: #{inspect(e)}")
            end

          _ ->
            Logger.debug("No session ID found in UserRemove message")
        end

        state

      # UserState = 9
      9 ->
        Logger.info("Received UserState message")

        # Use the proper decoder to extract userstate information
        user_state = MumbleChat.ProtobufHelper.decode_user_state(message_data)
        Logger.debug("Decoded UserState: #{inspect(user_state)}")

        # Only update our state if this UserState message contains our session or
        # if we're still waiting for a session ID
        new_state =
          cond do
            # If we have a session ID and this UserState is about us
            state.session_id != nil && user_state[:session_id] == state.session_id &&
                user_state[:channel_id] != nil ->
              Logger.info(
                "📍 Channel update - Our user moved to channel ID: #{user_state[:channel_id]}"
              )

              %{state | current_channel_id: user_state[:channel_id]}

            # If we don't have a session ID yet and this UserState contains our username
            # This can help identify our session before getting ServerSync
            state.session_id == nil && user_state[:name] != nil &&
              user_state[:session_id] != nil &&
                to_string(user_state[:name]) ==
                  (System.get_env("MUMBLE_USERNAME") || @default_username) ->
              Logger.info(
                "👤 Found potential session ID from UserState: #{user_state[:session_id]}"
              )

              if user_state[:channel_id] != nil do
                Logger.info("📍 Also found channel ID: #{user_state[:channel_id]}")

                %{
                  state
                  | session_id: user_state[:session_id],
                    current_channel_id: user_state[:channel_id]
                }
              else
                %{state | session_id: user_state[:session_id]}
              end

            # No relevant update
            true ->
              state
          end

        new_state

      # TextMessage = 11
      11 ->
        case MumbleChat.ProtobufHelper.decode_text_message(message_data) do
          {:ok, decoded} ->
            Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")
            handle_text_command(decoded.message, decoded.actor, state)

          decoded when is_map(decoded) ->
            Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")
            handle_text_command(decoded.message, decoded.actor, state)

          {:error, reason} ->
            Logger.error("Failed to decode text message: #{inspect(reason)}")
        end

        state

      # CryptSetup = 15
      15 ->
        Logger.info("Received CryptSetup message")

        # According to the Mumble connection sequence:
        # 1. TLS handshake (already done)
        # 2. Version exchange (already done)
        # 3. Client sends Authenticate (already done)
        # 4. Server sends CryptSetup (this message)
        # 5. Server sends Channel states (next)
        # 6. Server sends User states
        # 7. Server finally sends ServerSync with our session ID

        # Extract the server_nonce if present
        server_nonce =
          case :binary.match(message_data, <<26>>) do
            {pos, 1} ->
              try do
                # Get the length byte after the marker
                <<_::binary-size(pos + 1), nonce_len, nonce::binary-size(nonce_len),
                  _rest::binary>> = message_data

                Logger.info("Extracted server_nonce of length #{nonce_len}")
                nonce
              rescue
                e ->
                  Logger.error("Failed to extract server_nonce: #{inspect(e)}")
                  <<>>
              end

            _ ->
              Logger.debug("No server_nonce found in CryptSetup message")
              <<>>
          end

        # Also check for a key (for debugging)
        key_present =
          case :binary.match(message_data, <<10>>) do
            {_, 1} -> true
            _ -> false
          end

        if key_present do
          Logger.info("CryptSetup contains an encryption key")
        end

        # Generate a client_nonce of 16 random bytes
        # This is used for voice channel encryption (OCB-AES128)
        client_nonce = :crypto.strong_rand_bytes(16)
        Logger.info("Generated client_nonce of length 16 bytes")

        # Build a proper CryptSetup response
        # Per protocol, we need to acknowledge with both the client_nonce we generated
        # and the server_nonce we received
        response_data = build_crypt_setup_response(client_nonce, server_nonce)

        # Only respond if we received a server_nonce
        if byte_size(server_nonce) > 0 do
          Logger.info("🔐 Responding to CryptSetup with client_nonce and server_nonce")

          Logger.info(
            "This completes step 4 of connection sequence - expecting channel states next"
          )

          send_message(state.socket, 15, response_data)
        else
          Logger.debug("No server_nonce provided, no response needed")
        end

        state

      # PermissionQuery = 20
      20 ->
        Logger.info("Received PermissionQuery message")

        # Try to extract channel_id (field 1, ID 8)
        case :binary.match(message_data, <<8>>) do
          {pos, 1} ->
            try do
              <<_::binary-size(pos + 1), channel_id::little-32, _rest::binary>> = message_data
              Logger.info("PermissionQuery for channel ID: #{channel_id}")
            rescue
              e -> Logger.error("Error extracting channel ID from PermissionQuery: #{inspect(e)}")
            end

          _ ->
            Logger.debug("No channel ID found in PermissionQuery message")
        end

        state

      # CodecVersion = 21
      21 ->
        Logger.info("Received CodecVersion message")

        # This message tells us which audio codec versions the server supports
        # We're not implementing voice chat, so we'll just log it
        Logger.debug("Server sent codec version information")

        state

      # UserStats = 22
      22 ->
        Logger.debug("Received UserStats message")
        state

      # ServerConfig = 24
      24 ->
        Logger.info("Received ServerConfig message")

        # This message contains server configuration details
        # Such as max bandwidth, welcome text, etc.
        # We'll just log it for now
        Logger.debug("Server sent configuration information")

        state

      _ ->
        Logger.debug("Received unhandled message type: #{message_type}")
        state
    end
  end

  # Helper function to build a proper CryptSetup response
  defp build_crypt_setup_response(client_nonce, server_nonce) do
    # Field 2: client_nonce (marker 18, then length, then data)
    client_nonce_field = <<18, byte_size(client_nonce), client_nonce::binary>>

    # Field 3: server_nonce (marker 26, then length, then data)
    server_nonce_field = <<26, byte_size(server_nonce), server_nonce::binary>>

    # Combine the fields
    client_nonce_field <> server_nonce_field
  end

  @doc """
  Sends a text message to the specified channel.
  If no channel_id is provided, it will send to the current channel.
  """
  def send_message(text, channel_id \\ nil) do
    GenServer.cast(__MODULE__, {:send_text_message, text, channel_id})
  end

  @doc """
  Joins a specific channel by ID.
  This sends a UserState message to update our channel.
  """
  def join_channel(channel_id) do
    GenServer.cast(__MODULE__, {:join_channel, channel_id})
  end

  def handle_cast({:join_channel, channel_id}, %{socket: socket, session_id: session_id} = state) do
    if socket == nil || session_id == nil do
      Logger.error("Cannot join channel - not fully connected to server")
      {:noreply, state}
    else
      Logger.info("🚶 Joining channel #{channel_id}")

      # Create a UserState message with our session_id and the target channel_id
      # Field 1: session (uint32) - our session ID
      # Field 5: channel_id (uint32) - target channel ID
      message_data = <<8, session_id::little-32, 40, channel_id::little-32>>

      # Send UserState message (type 9)
      result = send_message(socket, 9, message_data)
      Logger.info("Join channel request result: #{inspect(result)}")

      # The server will respond with a UserState message that will update our state
      {:noreply, state}
    end
  end

  def handle_cast({:send_text_message, text, channel_id}, %{socket: socket} = state) do
    Logger.info("Attempting to send message: '#{text}' to channel: #{inspect(channel_id)}")

    if socket == nil do
      Logger.error("Cannot send message - not connected to server")
      {:noreply, state}
    else
      # Use the current channel ID if none specified
      target_channel_id = channel_id || state.current_channel_id

      # Check if we have the information needed to send a message
      cond do
        state.session_id == nil ->
          Logger.error(
            "❌ No session ID available - cannot send message. Still in authentication process?"
          )

          {:noreply, state}

        target_channel_id == nil ->
          Logger.error(
            "❌ No channel ID available - cannot send message. Please specify a channel ID or wait until we join a channel."
          )

          {:noreply, state}

        true ->
          Logger.info(
            "📤 Sending message as session #{state.session_id} to channel #{target_channel_id}"
          )

          message_data =
            MumbleChat.ProtobufHelper.create_text_message(
              text,
              target_channel_id,
              state.session_id
            )

          Logger.debug(
            "Message data (#{byte_size(message_data)} bytes): #{inspect(message_data, limit: 50)}"
          )

          # 11 is TextMessage type
          result = send_message(socket, 11, message_data)
          Logger.info("Message sent result: #{inspect(result)}")

          # Log the summary of the current connection state
          Logger.info(
            "📊 Connection state: session_id=#{state.session_id}, current_channel=#{state.current_channel_id}"
          )

          {:noreply, state}
      end
    end
  end

  @doc """
  Streams audio data from an OPUS file to the Mumble server through the TCP connection
  using the UDP tunnel.

  ## Parameters

  - `file_path`: Path to the OPUS audio file
  - `target`: Target for the audio packet (5 bits, default 0)
  """
  def stream_opus_file(file_path, target \\ 0) when target in 0..31 do
    GenServer.cast(__MODULE__, {:stream_opus_file, file_path, target})
  end

  def handle_cast({:send_text_message, text, channel_id}, %{socket: socket} = state) do
    message_data = MumbleChat.ProtobufHelper.create_text_message(text, channel_id)
    # 11 is TextMessage type
    send_message(socket, 11, message_data)
    {:noreply, state}
  end

  def handle_cast({:stream_opus_file, file_path, target}, %{socket: socket} = state) do
    case File.exists?(file_path) do
      true ->
        Logger.info("Starting to stream OPUS file: #{file_path}")
        # Start streaming in a separate process to not block the GenServer
        Task.start(fn -> stream_file_data(socket, file_path, target) end)
        {:noreply, state}

      false ->
        Logger.error("OPUS file not found: #{file_path}")
        {:noreply, state}
    end
  end

  # Streams file data in chunks
  defp stream_file_data(socket, file_path, target) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        stream_loop(socket, file, target)
        File.close(file)
        Logger.info("Finished streaming OPUS file: #{file_path}")

      {:error, reason} ->
        Logger.error("Failed to open OPUS file: #{inspect(reason)}")
    end
  end

  # Reads and sends file data in chunks
  defp stream_loop(socket, file, target) do
    case IO.binread(file, @chunk_size) do
      data when is_binary(data) and byte_size(data) > 0 ->
        # Create audio packet with proper header
        packet = create_audio_packet(data, target)

        # Send through UDP tunnel
        send_udp_tunnel(socket, packet)

        # Add a small delay to control streaming rate (adjust as needed)
        Process.sleep(20)

        # Continue with next chunk
        stream_loop(socket, file, target)

      _ ->
        # End of file or error
        :ok
    end
  end

  # Creates an audio packet with the proper header
  # Format: 3 bits for type (4 for OPUS) + 5 bits for target
  defp create_audio_packet(data, target) do
    # Create header: type (4 for OPUS) in 3 most significant bits + target in 5 least significant bits
    header = (@audio_type_opus <<< 5) ||| (target &&& 0x1F)

    # Combine header with data
    <<header::size(8), data::binary>>
  end

  # Sends data through the UDP tunnel (message type 1)
  defp send_udp_tunnel(socket, packet) do
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

  # Handle text commands from users
  defp handle_text_command(message, actor, %{socket: socket} = state) do
    case parse_play_command(message) do
      {:play, url} ->
        Logger.info("Received !play command with URL: #{url}")
        handle_play_command(url, socket)
        :ok
      _ ->
        # Not a recognized command, ignore
        :ok
    end
  end

  # Parse a message to check if it's a !play command
  defp parse_play_command(message) do
    # Trim whitespace and check if it starts with !play
    case String.trim(message) do
      "!play " <> rest ->
        # Extract the URL from the rest of the message
        url = String.trim(rest)
        {:play, url}
      _ ->
        :not_play_command
    end
  end

  # Handle a play command with the given URL
  defp handle_play_command(url, socket) do
    # Send a message indicating we're processing the request
    send_feedback_message("Processing !play request for: #{url}", socket)

    # Use MediaDownloader to download the audio
    # Set a reasonable max size (100MB)
    max_size_bytes = 100 * 1024 * 1024

    # Start the download in a separate process to not block the GenServer
    Task.start(fn ->
      case MediaDownloader.download_audio(url, max_size_bytes) do
        {:ok, file_path} ->
          # Download successful, send feedback and start streaming
          send_feedback_message("Download complete. Starting playback...", socket)
          stream_opus_file(file_path)

          # Clean up the file after streaming (optional)
          # You might want to keep it for caching purposes
          # File.rm(file_path)

        {:error, :invalid_url} ->
          send_feedback_message("Error: Invalid URL provided", socket)

        {:error, {:yt_dlp_error, error}} ->
          send_feedback_message("Error downloading audio: #{inspect(error)}", socket)

        {:error, {:file_too_large, size, max}} ->
          send_feedback_message("Error: File too large (#{size} bytes, max: #{max} bytes)", socket)

        {:error, reason} ->
          send_feedback_message("Error: #{inspect(reason)}", socket)
      end
    end)
  end

  # Send a feedback message to the channel
  defp send_feedback_message(text, socket) do
    # Create a text message with no specific channel (current channel)
    message_data = MumbleChat.ProtobufHelper.create_text_message(text, nil)
    # Send as TextMessage (type 11)
    send_message(socket, 11, message_data)
  end
end
