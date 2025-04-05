defmodule MumbleChat.Client do
  @moduledoc """
  A client implementation for the Mumble voice chat protocol.

  This module provides functionality to connect to a Mumble server,
  send and receive text messages, join channels, and stream audio content.
  It implements the Mumble protocol over a TLS connection.

  ## Features

  * Connect to a Mumble server with authentication
  * Send and receive text messages
  * Join channels
  * Stream audio content from files
  * Process command messages (!play, !pause, !resume)

  ## Configuration

  The client is configured using environment variables:

  * `MUMBLE_HOST` - Server hostname (default: "localhost")
  * `MUMBLE_PORT` - Server port (default: 64738)
  * `MUMBLE_USERNAME` - Username for authentication (default: "ElixirMumbleClient")

  ## Usage

  ```elixir
  # Start the client
  MumbleChat.Client.start_link([])

  # Send a message to the current channel
  MumbleChat.Client.send_message("Hello world!")

  # Join a specific channel
  MumbleChat.Client.join_channel(1)

  # Stream an audio file
  MumbleChat.Client.stream_opus_file("/path/to/audio.opus")
  ```
  """

  use Bitwise
  use GenServer
  require Logger
  import Bitwise

  # Connection defaults
  @default_host "localhost"
  @default_port 64738
  @default_username "ElixirMumbleClient"

  # Version information
  @version_major 1
  @version_minor 3
  @version_patch 0

  # Message types
  @udp_tunnel_type 1

  @doc """
  Starts the Mumble client as a linked GenServer process.

  Uses the application environment or default values for connection parameters.
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Get configuration from environment or use defaults
    host = System.get_env("MUMBLE_HOST") || @default_host
    port = (System.get_env("MUMBLE_PORT") || @default_port) |> to_string() |> String.to_integer()
    username = System.get_env("MUMBLE_USERNAME") || @default_username

    # Log connection intent
    Logger.info("Connecting to Mumble server at #{host}:#{port} as #{username}")

    # Schedule a connection attempt
    Process.send_after(self(), {:connect, host, port, username}, 100)

    # Start status timer
    status_timer = Process.send_after(self(), :log_status, 5000)

    # Get current time for audio sequence initialization
    current_time = System.system_time(:millisecond)
    Logger.info("Initializing audio sequence tracking at time #{current_time}")

    # Return initial state
    {:ok,
     %{
       socket: nil,
       ping_timer: nil,
       connect_attempts: 0,
       session_id: nil,
       current_channel_id: nil,
       status_timer: status_timer,
       buffer: <<>>,

       # Audio sequence tracking (all sequences start at 0)
       audio_sequence: 0,
       audio_sequence_start_time: current_time,
       audio_sequence_last_time: current_time
     }}
  end

  #
  # GenServer Callbacks - Connection related
  #

  @doc false
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

  @doc false
  def handle_info(:send_ping, %{socket: socket} = state) do
    ping_data = MumbleChat.ProtobufHelper.create_ping(System.system_time(:millisecond))
    MumbleChat.Messaging.send_message(socket, 3, ping_data)
    {:noreply, %{state | ping_timer: start_ping_timer()}}
  end

  @doc false
  def handle_info({:ssl, socket, data}, state) when is_list(data) do
    # Convert the received list of bytes to binary before processing
    binary_data = :erlang.list_to_binary(data)
    handle_info({:ssl, socket, binary_data}, state)
  end

  @doc false
  def handle_info({:ssl, socket, data}, %{buffer: buffer} = state) when is_binary(data) do
    # Store current state in process dictionary
    store_state_in_process_dictionary(state)

    # Append the new data to any existing buffer
    combined_data = buffer <> data

    # Process the combined data
    {new_state, remaining_data} = process_data(combined_data, state)

    # Keep any unprocessed data in the buffer
    {:noreply, %{new_state | buffer: remaining_data}}
  end

  # Handle case where we don't have a buffer in the state yet
  @doc false
  def handle_info({:ssl, socket, data}, state) when is_binary(data) do
    # Store current state in process dictionary
    store_state_in_process_dictionary(state)

    # Initialize buffer and delegate to the version with buffer
    handle_info({:ssl, socket, data}, Map.put(state, :buffer, <<>>))
  end

  @doc false
  def handle_info({:ssl_closed, _socket}, state) do
    Logger.error("SSL connection closed")
    {:stop, :normal, state}
  end

  @doc false
  def handle_info({:ssl_error, _socket, reason}, state) do
    Logger.error("SSL error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  @doc false
  def handle_info(:log_status, state) do
    # Reschedule the status report
    status_timer = Process.send_after(self(), :log_status, 5000)
    {:noreply, %{state | status_timer: status_timer}}
  end

  #
  # GenServer Callbacks - Commands and actions
  #

  @doc false
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
      result = MumbleChat.Messaging.send_message(socket, 9, message_data)
      Logger.info("Join channel request result: #{inspect(result)}")

      # The server will respond with a UserState message that will update our state
      {:noreply, state}
    end
  end

  @doc false
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

          # Send message using the Messaging module
          MumbleChat.Messaging.send_text_message(
            socket,
            # 11 is TextMessage type
            11,
            text,
            target_channel_id,
            state.session_id
          )

          # Log the summary of the current connection state
          Logger.info(
            "📊 Connection state: session_id=#{state.session_id}, current_channel=#{state.current_channel_id}"
          )

          {:noreply, state}
      end
    end
  end

  @doc false
  def handle_cast({:stream_opus_file, file_path, target}, %{socket: socket} = state) do
    case File.exists?(file_path) do
      true ->
        Logger.info("Starting to stream OPUS file: #{file_path}")
        # Start streaming in a separate process using the Audio module
        Task.start(fn -> MumbleChat.Audio.stream_file_data(socket, file_path, target) end)
        {:noreply, state}

      false ->
        Logger.error("OPUS file not found: #{file_path}")
        {:noreply, state}
    end
  end

  @doc false
  def handle_cast({:send_audio_packet, packet}, %{socket: socket} = state) do
    if socket != nil do
      MumbleChat.Audio.send_udp_tunnel(socket, packet)
    else
      Logger.error("Cannot send audio packet - not connected to server")
    end

    {:noreply, state}
  end

  @doc false
  def handle_call({:get_state_for_feedback, callback}, _from, state) do
    # Execute the callback with the current state
    callback.(state)
    {:reply, :ok, state}
  end

  #
  # Private helper functions - Protocol related
  #

  @doc """
  Processes received data, extracting Mumble protocol messages.

  This function handles the binary protocol format of Mumble, which consists of
  a message type (2 bytes), message length (4 bytes), and the message data.
  """
  defp process_data(data, state) do
    case data do
      # Check if we have at least a complete header (6 bytes: 2 for type, 4 for length)
      <<message_type::size(16), message_length::size(32), rest::binary>> = all_data ->
        # Check if we have the complete message
        if byte_size(rest) >= message_length do
          # Extract the message data
          <<message_data::binary-size(message_length), remaining::binary>> = rest

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

  @doc """
  Initializes a timer to send periodic ping messages to the server.
  """
  defp start_ping_timer do
    Process.send_after(self(), :send_ping, 15000)
  end

  @doc """
  Handles a Mumble protocol message based on its type.
  """
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
        handle_server_sync(message_data, state)

      # ChannelRemove = 6
      6 ->
        Logger.info("Received ChannelRemove message")
        state

      # ChannelState = 7
      7 ->
        handle_channel_state(message_data, state)

      # UserRemove = 8
      8 ->
        handle_user_remove(message_data, state)

      # UserState = 9
      9 ->
        handle_user_state(message_data, state)

      # TextMessage = 11
      11 ->
        handle_received_text_message(message_data, state)

      # CryptSetup = 15
      15 ->
        handle_crypt_setup(message_data, state)

      # PermissionQuery = 20
      20 ->
        handle_permission_query(message_data, state)

      # CodecVersion = 21
      21 ->
        Logger.info("Received CodecVersion message")
        Logger.debug("Server sent codec version information")
        state

      # UserStats = 22
      22 ->
        Logger.debug("Received UserStats message")
        state

      # ServerConfig = 24
      24 ->
        Logger.info("Received ServerConfig message")
        Logger.debug("Server sent configuration information")
        state

      _ ->
        Logger.debug("Received unhandled message type: #{message_type}")
        state
    end
  end

  @doc """
  Initiates a connection to a Mumble server.

  ## Parameters

  - `host`: The hostname or IP address of the Mumble server
  - `port`: The port number of the Mumble server
  - `username`: The username to authenticate with

  ## Returns

  - `{:ok, state}` on successful connection
  - `{:error, reason}` on connection failure
  """
  def connect(host, port, username) do
    # SSL connection options
    ssl_options = [
      verify: :verify_none,
      active: true
    ]

    case :ssl.connect(String.to_charlist(host), port, ssl_options) do
      {:ok, socket} ->
        Logger.info("Connected to Mumble server successfully")

        # Send version information
        version = <<@version_major::size(16), @version_minor::size(8), @version_patch::size(8)>>
        MumbleChat.Messaging.send_message(socket, 0, version)

        # Send authentication
        auth_data = MumbleChat.ProtobufHelper.create_authenticate(username, "", true)
        MumbleChat.Messaging.send_message(socket, 2, auth_data)

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

  @doc """
  Sends a text message to a channel on the Mumble server.

  ## Parameters

  - `text`: The message text to send
  - `channel_id`: (Optional) The ID of the channel to send the message to.
                  Defaults to the current channel if nil.
  """
  def send_message(text, channel_id \\ nil) do
    GenServer.cast(__MODULE__, {:send_text_message, text, channel_id})
  end

  @doc """
  Joins a specific channel on the Mumble server.

  ## Parameters

  - `channel_id`: The ID of the channel to join
  """
  def join_channel(channel_id) do
    GenServer.cast(__MODULE__, {:join_channel, channel_id})
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

  # Store state in process dictionary before processing messages
  defp store_state_in_process_dictionary(state) do
    Process.put(:current_state, state)
    state
  end

  # Helper functions for handling specific message types

  defp handle_server_sync(message_data, state) do
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
  end

  defp handle_channel_state(message_data, state) do
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
  end

  defp handle_user_remove(message_data, state) do
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
  end

  defp handle_user_state(message_data, state) do
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
          Logger.info("👤 Found potential session ID from UserState: #{user_state[:session_id]}")

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
  end

  defp handle_received_text_message(message_data, state) do
    case MumbleChat.ProtobufHelper.decode_text_message(message_data) do
      {:ok, decoded} ->
        Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")

        MumbleChat.Messaging.handle_text_command(
          decoded.message,
          decoded.actor,
          state.socket,
          state.session_id,
          state.current_channel_id
        )

      decoded when is_map(decoded) ->
        Logger.info("Chat message from session #{decoded.actor}: #{decoded.message}")

        MumbleChat.Messaging.handle_text_command(
          decoded.message,
          decoded.actor,
          state.socket,
          state.session_id,
          state.current_channel_id
        )

      {:error, reason} ->
        Logger.error("Failed to decode text message: #{inspect(reason)}")
    end

    state
  end

  defp handle_crypt_setup(message_data, state) do
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
            <<_::binary-size(pos + 1), nonce_len, nonce::binary-size(nonce_len), _rest::binary>> =
              message_data

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

      Logger.info("This completes step 4 of connection sequence - expecting channel states next")

      MumbleChat.Messaging.send_message(state.socket, 15, response_data)
    else
      Logger.debug("No server_nonce provided, no response needed")
    end

    state
  end

  defp handle_permission_query(message_data, state) do
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
end
