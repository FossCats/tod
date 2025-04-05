defmodule MumbleChat.Client do
  use GenServer
  require Logger

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

    # Return initial state without connection
    {:ok, %{socket: nil, ping_timer: nil, connect_attempts: 0, session_id: nil}}
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

    # Check if the certificate file exists
    if not File.exists?(to_string(cert_path)) do
      Logger.error("Certificate file does not exist at path: #{inspect(cert_path)}")
      {:stop, :certificate_not_found}
    else
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
          send_message(socket, 0, version)

          # Send authentication (username, password, etc.)
          auth_data = MumbleChat.ProtobufHelper.create_authenticate(username, "", true)
          send_message(socket, 2, auth_data)

          {:ok, %{socket: socket, ping_timer: start_ping_timer(), connect_attempts: 0}}

        {:error, {:options, option_error}} ->
          Logger.error("SSL option error: #{inspect(option_error)}")
          {:stop, {:ssl_option_error, option_error}}

        {:error, reason} ->
          Logger.error("Failed to connect to Mumble server: #{inspect(reason)}")
          {:error, reason}
      end
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

  def handle_info({:ssl, socket, data}, state) when is_binary(data) do
    # Handle incoming SSL data
    <<message_type::size(16), _message_length::size(32), message_data::binary>> = data

    case handle_message(message_type, message_data, state) do
      {:ok, new_state} ->
        # State was updated
        {:noreply, new_state}
      _ ->
        # No state update
        {:noreply, state}
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
        :ok

      # UDPTunnel = 1
      1 ->
        Logger.debug("Received UDPTunnel message")
        :ok

      # Authenticate = 2
      2 ->
        Logger.debug("Received Authenticate message")
        :ok

      # Ping = 3
      3 ->
        Logger.debug("Received Ping message")
        :ok

      # Reject = 4
      4 ->
        Logger.debug("Received Reject message")
        :ok

      # ServerSync = 5
      5 ->
        Logger.debug("Received ServerSync message")
        # Extract and store our session ID from ServerSync
        session_id = extract_session_from_sync(message_data)
        Logger.info("Server assigned us session ID: #{session_id}")
        # Return the session ID to be stored in state
        {:ok, %{state | session_id: session_id}}

      # TextMessage = 11
      11 ->
        case MumbleChat.ProtobufHelper.decode_text_message(message_data) do
          {:ok, decoded} ->
            Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")

          decoded when is_map(decoded) ->
            Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")

          {:error, reason} ->
            Logger.error("Failed to decode text message: #{inspect(reason)}")
        end

      # UserStats = 15
      15 ->
        Logger.debug("Received UserStats message")
        :ok

      _ ->
        Logger.debug("Received unhandled message type: #{message_type}")
        :ok
    end
  end

  # Helper to extract our session ID from ServerSync message
  defp extract_session_from_sync(data) do
    # ServerSync message has session ID as first field (field 1)
    case data do
      <<8, session_id::little-32, _rest::binary>> ->
        session_id
      _ ->
        Logger.error("Could not extract session ID from ServerSync message")
        nil
    end
  end

  @doc """
  Sends a text message to the specified channel.
  If no channel_id is provided, it will send to the current channel.
  """
  def send_message(text, channel_id \\ nil) do
    GenServer.cast(__MODULE__, {:send_text_message, text, channel_id})
  end

  def handle_cast({:send_text_message, text, channel_id}, %{socket: socket, session_id: session_id} = state) do
    Logger.info("Attempting to send message: '#{text}' to channel: #{inspect(channel_id)}")

    if socket == nil do
      Logger.error("Cannot send message - not connected to server")
      {:noreply, state}
    else
      if session_id == nil do
        Logger.warning("Session ID not yet received from server - message might not be delivered properly")
      end

      message_data = MumbleChat.ProtobufHelper.create_text_message(text, channel_id, session_id)

      # 11 is TextMessage type
      result = send_message(socket, 11, message_data)
      Logger.info("Message sent result: #{inspect(result)}")
      {:noreply, state}
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
end
