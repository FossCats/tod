defmodule MumbleChat.Client do
  use GenServer
  require Logger

  @default_host "localhost"
  @default_port 64738
  @default_username "ElixirMumbleClient"
  @version_major 1
  @version_minor 3
  @version_patch 0

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
    {:ok, %{socket: nil, ping_timer: nil, connect_attempts: 0}}
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
    <<message_type::size(16), message_length::size(32), message_data::binary>> = data
    handle_message(message_type, message_data, state)
    {:noreply, state}
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
    :ssl.send(socket, [header, message_data])
  end

  defp handle_message(message_type, message_data, _state) do
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
        :ok

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

  @doc """
  Sends a text message to the specified channel.
  If no channel_id is provided, it will send to the current channel.
  """
  def send_message(text, channel_id \\ nil) do
    GenServer.cast(__MODULE__, {:send_text_message, text, channel_id})
  end

  def handle_cast({:send_text_message, text, channel_id}, %{socket: socket} = state) do
    message_data = MumbleChat.ProtobufHelper.create_text_message(text, channel_id)
    # 11 is TextMessage type
    send_message(socket, 11, message_data)
    {:noreply, state}
  end
end
