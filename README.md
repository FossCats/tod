# TOD - Telegraphed Opus Delivery
Tod takes your mad sus mumble server and make it bussin' on god frfr by delivering straigh bops to the ears 🔥

Design doc can be seen [here](https://github.com/FossCats/tod/blob/main/DESIGN.md)

# Getting Started
Start a mumble server on your local machine. 
```bash
make mumble
```

Then, run the following command to start the bot:
```bash
make run
```
This will start the bot and connect it to the mumble server.

# Audio Streaming
TOD supports streaming OPUS audio files to the Mumble server. You can use the following function to stream an OPUS file:

```elixir
# Stream an OPUS file to the Mumble server
MumbleChat.Client.stream_opus_file("/path/to/your/audio.opus")

# You can also specify a target (0-31) for the audio packet
MumbleChat.Client.stream_opus_file("/path/to/your/audio.opus", 5)
```

The audio data is streamed through the TCP connection using the UDP tunnel, which is useful when direct UDP communication is not available or blocked.

## Example Script

An example script is provided to demonstrate how to stream an OPUS file to a Mumble server:

```bash
# Run the example script with an OPUS file
./examples/stream_opus.exs /path/to/your/audio.opus

# You can also specify a target (0-31) for the audio packet
./examples/stream_opus.exs /path/to/your/audio.opus 5
```

The script will:
1. Connect to the Mumble server
2. Stream the specified OPUS file
3. Keep running until you press Ctrl+C to exit

## How It Works

1. The function reads the OPUS file in chunks
2. Each chunk is formatted as a Mumble audio packet with the proper header
3. The packets are sent through the TCP connection using the UDP tunnel
4. The audio is played on the Mumble server

This implementation follows the Mumble protocol specification for audio data transmission, using message type 4 (OPUS) for the audio packets and message type 1 (UDPTunnel) for the TCP tunnel.
