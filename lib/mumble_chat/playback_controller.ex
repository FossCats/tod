defmodule MumbleChat.PlaybackController do
  @moduledoc """
  Controls the playback of audio in the Mumble client.
  Manages play, pause, resume, and stop functionality.
  """
  use GenServer
  require Logger

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Plays audio from the given file path
  """
  def play(file_path, target \\ 0) do
    GenServer.call(__MODULE__, {:play, file_path, target})
  end

  @doc """
  Pauses the current playback
  """
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resumes the current playback if paused
  """
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Stops the current playback
  """
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc """
  Gets the current playback status
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  def init(_) do
    {:ok,
     %{
       status: :stopped,
       current_file: nil,
       playback_task: nil,
       target: 0,
       position: 0
     }}
  end

  @impl true
  def handle_call({:play, file_path, target}, _from, state) do
    # If already playing, stop the current playback first
    new_state =
      if state.status in [:playing, :paused] do
        do_stop(state)
      else
        state
      end

    # Start new playback
    case File.exists?(file_path) do
      true ->
        # Check if the file is an Opus file or convert it
        case ensure_opus_format(file_path) do
          {:ok, opus_path} ->
            Logger.info("Starting playback of Opus file: #{opus_path}")

            # Start the playback in a separate task
            task =
              Task.async(fn ->
                stream_file(opus_path, target, self())
              end)

            {:reply, :ok,
             %{
               new_state
               | status: :playing,
                 current_file: opus_path,
                 playback_task: task,
                 target: target,
                 position: 0
             }}

          {:error, reason} ->
            Logger.error("Error preparing file for playback: #{inspect(reason)}")
            {:reply, {:error, reason}, new_state}
        end

      false ->
        Logger.error("File not found: #{file_path}")
        {:reply, {:error, :file_not_found}, new_state}
    end
  end

  @impl true
  def handle_call(:pause, _from, %{status: :playing} = state) do
    Logger.info("Pausing playback")

    # Signal the streaming task to pause
    if state.playback_task do
      send(state.playback_task.pid, :pause)
    end

    {:reply, :ok, %{state | status: :paused}}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    # Can't pause if not playing
    {:reply, {:error, :not_playing}, state}
  end

  @impl true
  def handle_call(:resume, _from, %{status: :paused} = state) do
    Logger.info("Resuming playback")

    # Signal the streaming task to resume
    if state.playback_task do
      send(state.playback_task.pid, :resume)
    end

    {:reply, :ok, %{state | status: :playing}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    # Can't resume if not paused
    {:reply, {:error, :not_paused}, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status_info = %{
      status: state.status,
      current_file: state.current_file,
      position: state.position
    }

    {:reply, status_info, state}
  end

  @impl true
  def handle_info({:position_update, position}, state) do
    # Update the current position
    {:noreply, %{state | position: position}}
  end

  @impl true
  def handle_info({:playback_complete}, state) do
    Logger.info("Playback completed")
    new_state = %{state | status: :stopped, playback_task: nil, position: 0}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:playback_error, error}, state) do
    Logger.error("Playback error: #{inspect(error)}")
    new_state = %{state | status: :stopped, playback_task: nil}
    {:noreply, new_state}
  end

  # When a task completes or fails
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # The task completed successfully, we'll get a DOWN message next
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{playback_task: %Task{ref: task_ref}} = state
      )
      when ref == task_ref do
    # Task completed normally
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{playback_task: %Task{ref: task_ref, pid: task_pid}} = state
      )
      when ref == task_ref and pid == task_pid do
    # Task failed
    Logger.error("Playback task failed: #{inspect(reason)}")
    {:noreply, %{state | status: :stopped, playback_task: nil}}
  end

  # Helper functions

  defp do_stop(state) do
    if state.playback_task do
      # Signal the streaming task to stop
      if Process.alive?(state.playback_task.pid) do
        send(state.playback_task.pid, :stop)
        # Wait a bit for the task to clean up
        Process.sleep(100)
      end

      # Ensure the task is killed if it didn't stop gracefully
      Task.shutdown(state.playback_task, :brutal_kill)
    end

    %{state | status: :stopped, playback_task: nil, position: 0}
  end

  # Function to stream a file and send it to Mumble
  defp stream_file(file_path, target, controller_pid) do
    try do
      # Open the file
      {:ok, file} = File.open(file_path, [:read, :binary])

      # Get file size for tracking progress
      {:ok, %{size: file_size}} = File.stat(file_path)

      # Stream the file in chunks
      # Same as in MumbleChat.Client
      chunk_size = 1000
      position = 0
      stream_chunks(file, position, file_size, chunk_size, target, controller_pid)

      # Notify controller that playback is complete
      send(controller_pid, {:playback_complete})
    rescue
      e ->
        Logger.error("Error streaming file: #{inspect(e)}")
        send(controller_pid, {:playback_error, e})
    end
  end

  # Recursive function to stream chunks of the file with proper timing
  defp stream_chunks(
         file,
         position,
         file_size,
         chunk_size,
         target,
         controller_pid,
         paused \\ false,
         sequence \\ 0,
         sequence_start_time \\ nil,
         sequence_last_time \\ nil
       ) do
    # Initialize timing if not provided
    sequence_start_time = sequence_start_time || System.system_time(:millisecond)
    sequence_last_time = sequence_last_time || sequence_start_time
    current_time = System.system_time(:millisecond)

    # Check for control messages
    receive do
      :pause ->
        # Pause playback by recursing with paused flag
        stream_chunks(
          file,
          position,
          file_size,
          chunk_size,
          target,
          controller_pid,
          true,
          sequence,
          sequence_start_time,
          sequence_last_time
        )

      :resume ->
        # Resume playback with timing reset
        new_start_time = System.system_time(:millisecond)

        stream_chunks(
          file,
          position,
          file_size,
          chunk_size,
          target,
          controller_pid,
          false,
          sequence,
          new_start_time,
          new_start_time
        )

      :stop ->
        # Stop playback
        File.close(file)
        :stopped
    after
      0 ->
        # No control message, handle playback
        if paused do
          # If paused, wait a bit and check again for control messages
          Process.sleep(100)

          stream_chunks(
            file,
            position,
            file_size,
            chunk_size,
            target,
            controller_pid,
            paused,
            sequence,
            sequence_start_time,
            sequence_last_time
          )
        else
          # Time to send a packet?
          if sequence_last_time + MumbleChat.Client.audio_per_packet() <= current_time do
            # Read the next chunk
            case IO.binread(file, chunk_size) do
              data when is_binary(data) and byte_size(data) > 0 ->
                # Calculate new sequence and timing
                {new_sequence, new_last_time, new_start_time} =
                  MumbleChat.Client.calculate_sequence_timing(
                    sequence,
                    sequence_start_time,
                    sequence_last_time,
                    current_time
                  )

                # Log the sequence information
                Logger.debug("PlaybackController sending packet with sequence: #{new_sequence}")

                # Create and send audio packet with sequence
                packet =
                  MumbleChat.Client.create_audio_packet_with_sequence(data, target, new_sequence)

                MumbleChat.Client.send_audio_packet(packet)

                # Update position
                new_position = position + byte_size(data)
                progress_percentage = Float.round(new_position / file_size * 100, 1)

                # Send position update every ~5% or at least every 1MB
                if rem(round(progress_percentage), 5) == 0 or new_position - position >= 1_000_000 do
                  send(controller_pid, {:position_update, new_position})
                end

                # Wait a small amount of time before next read
                Process.sleep(5)

                # Continue with next chunk
                stream_chunks(
                  file,
                  new_position,
                  file_size,
                  chunk_size,
                  target,
                  controller_pid,
                  paused,
                  new_sequence,
                  new_start_time,
                  new_last_time
                )

              _ ->
                # End of file or error
                File.close(file)
                :done
            end
          else
            # Not time to send a packet yet
            Process.sleep(5)

            stream_chunks(
              file,
              position,
              file_size,
              chunk_size,
              target,
              controller_pid,
              paused,
              sequence,
              sequence_start_time,
              sequence_last_time
            )
          end
        end
    end
  end

  # Ensure the file is in Opus format, converting if necessary
  defp ensure_opus_format(file_path) do
    if Path.extname(file_path) == ".opus" do
      # Already an opus file
      {:ok, file_path}
    else
      # Need to convert to opus
      Logger.info("Converting file to Opus format: #{file_path}")
      AudioEncoder.encode_to_opus(file_path)
    end
  end
end
