## 1. Overview
- Purpose: Audio streaming bot for Mumble voice chat
- Primary Language: Elixir
- Deployment: Containerized
As a mumble server admin, adding this music bot to my server should be as easy as:
```sh
git clone <url> && docker-compose up
```
or similar
- Performance: Blazingly fast.

## 2. Core Features
- Mumble Server Connection
- Commands / Actions
- YouTube Audio Streaming
- Playlist Management

## 3. Technical Components

### 3.1 Mumble Integration
- Library: [Mumble protocol library]()
  - Create mumble library to publish to [hex](https://hex.pm)?

- Connection Management
- Channel Joining/Leaving
  - Config / Env file to determine server / channel
- Voice Chat Interaction?
  - AI interaction for voice commands / TTS - STT, 11labs??

### 3.2 Command Handling
- Prefix: '!'
- Supported Commands:
  - !play <youtube_link>
  - !pause
  - !skip
  - !queue <url> (adds url to queue)
  - !clear (clears queue)
  - !volume <val> (value 1-100 or %)
  - !shuffle (plays downloaded songs)
  - !help (shows commands)

### 3.3 Audio Streaming
- Runtime dependency: yt-dlp (containerized)
- Streaming Mechanism
- Audio Conversion
- Buffering?

### 3.4 Web Frontend
- Optional Management Interface with Phoenix Liveview?
- Playlist Editing
- Bot Controls
- Administration

## 4. Architecture
Message passing??

## 5. Containerization
- Docker Compose Setup
- Runtime yt-dlp


## 6. Error Handling
- Connection Failures
- Stream Interruptions
- Invalid Commands

## 7. Performance Considerations
- Concurrent Stream Handling
- Rate Limiting

## 8. Security
- Command Authentication
- Link Validation
- Rate Limiting

# Job Division

## 1. Mumble protocol implementation

Refer to mumble protocol [here](https://github.com/mumble-voip/mumble/blob/master/docs/dev/network-protocol/README.md)
Proto files of the protocol:
[Mumble.proto](https://github.com/mumble-voip/mumble/blob/master/src/Mumble.proto)
[MumbleUDP.proto](https://github.com/mumble-voip/mumble/blob/master/src/MumbleUDP.proto)

Provides:
- API for bot:
  - `Server.connect(<details>)`
  - `Server.stream(<audio>)`
  - `Server.watchChat(<callback>)`
  - `Server.disconnect()`
  - `Server.listChannels()`
  - `Server.listClients(<channel>)`
  - `Server.sendChat(<channel>)`
  - `Server.sendChat(<channel>, <client>)` ;; to single individual

Or something similar

## 2. youtube download / stream

Basically needs to implement a `getAudio(<yt_url>)` function that take url as input and returns a stream of audio in the correct format to send to the server

Whats also necessary to figure out with this implementation is how to depend on yt-dlp in a secure and up-to-date manner. Runtime dependency allows us to fetch the latest yt-dlp to get around any new YT blockades, but can open us up to downloading exploits or vulnerable code.

Optionally, cache each download and check against cache to see if no download is necessary to play.

## 3. Core Glue Guts

- _Main_ Connecting the server actions with YT audio and setting up the process as a running daemon, listening to commands, maintaining a playlist of songs, buffering streams, receiving commands from admin panel, etc.
- _Config_ Reading from config file to determine app settings (connection details, etc). Possibly storing any config / state in sqlite or just plaintext?

## 3. Admin Panel (Optional)

Phoenix Liveview (or other) Server side rendered frontend. Can be fairly basic with all chat-supported actions as well as more administrative actions. Whitelist / blacklist users to send commands to bot, setting ratelimit of bot, etc.

## 4. AI Integration (Optional for VC funding / valuation)

Provided API keys for various AI services and a stream of the channel audio, what sort of commands / functionality can we implement for the bot?

## 5. Audio Engineering (Optional)

Support for stereo sound? Mumble 1.4.0 supports stereo, what is required to ensure downloads / stream supports it also?
Audio ducking functionality (auto dimming when people are talking, and then resuming at normal volume on silence).
