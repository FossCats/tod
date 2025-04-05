## 1. Overview
- Purpose: Audio streaming bot for Mumble voice chat
- Stack: Elixir + Docker
- Simple deployment via `docker-compose up`

## 2. Core Features
- Mumble server connection & audio streaming
- YouTube audio playback with playlist management
- Command interface (!play, !pause, etc.)

## 3. Technical Components

### 3.1 Mumble Integration
- Custom Mumble protocol library implementation
- Connection & channel management via config
- Voice interaction capabilities (optional)

### 3.2 Command Interface
- !play <url>
- !pause/!skip
- !queue/!clear
- !volume <1-100>
- !help

### 3.3 Audio Pipeline
- YouTube download via yt-dlp
- Audio format conversion
- Stream buffering
- Optional: Stereo support, audio ducking

### 3.4 Optional Features
- Web admin interface (Phoenix LiveView)
- AI voice interaction
- Advanced audio controls

## 4. Implementation Priorities

### Phase 1: Core Protocol
- Mumble protocol implementation
- Basic server operations (connect, stream, chat)
- YouTube audio extraction

### Phase 2: Bot Logic
- Command handling
- Playlist management
- Configuration system

### Phase 3: Extensions
- Web interface
- AI integration
- Advanced audio features

## 5. Security & Performance
- Command authentication
- Rate limiting
- Stream optimization
- Error handling