use anyhow::{Context, Result, anyhow};
use mumble_rs::{
    MumbleClient,
    audio::{AudioCodec, AudioRecvConfig, AudioSendConfig},
    config::Config,
    error::Error as MumbleError,
    events::{Event, TextMessage},
};
use rubato::{ResampleRatio, Resampler, SincFixedIn, WindowFunction};
use rustube::{self, Id, Video};
use std::{fs::File, io::BufReader, path::PathBuf, sync::Arc, time::Duration};
use symphonia::core::{
    audio::{AudioBuffer, AudioBufferRef, SampleBuffer, SignalSpec},
    codecs::{CODEC_TYPE_NULL, DecoderOptions},
    errors::Error as SymphoniaError,
    formats::{FormatOptions, FormatReader, SeekMode, SeekTo},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::Time,
};
use tokio::sync::{Mutex, mpsc};

// ---+------------------------------------------------------+---
// ---|                  CONFIGURATION                       |---
// ---|   !!! REPLACE THESE WITH YOUR ACTUAL VALUES !!!      |---
// ---| Consider loading from environment variables or file  |---
// ---+------------------------------------------------------+---
const SERVER_ADDR: &str = "mumble.fosscat.com"; // e.g., "mumble.example.org"
const SERVER_PORT: u16 = 64738; // Default Mumble port
const USERNAME: &str = "YouTubeBot"; // Bot's username
const PASSWORD: Option<&str> = None; // Set to Some("your_password") if needed
const CERT_PATH: &str = "../priv/cert.p12"; // Path to client certificate
// const KEY_PATH: &str = "path/to/your/client_key.pem"; // Path to client private key (unencrypted)

// Audio playback settings
const TARGET_SAMPLE_RATE: u32 = 48000; // Mumble typically uses 48kHz
const TARGET_CHANNELS: usize = 1; // 1 for Mono, 2 for Stereo (Mono is often preferred for bots)
const PLAYBACK_COMMAND: &str = "!play "; // Command prefix
// ---+------------------------------------------------------+---

// Define custom errors for better context
#[derive(Debug, thiserror::Error)]
enum BotError {
    #[error("Audio processing error: {0}")]
    AudioProcessing(String),
    #[error("YouTube error: {0}")]
    YouTube(String),
    #[error("Mumble client error: {0}")]
    Mumble(#[from] MumbleError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("Resampling error: {0}")]
    Resampling(#[from] rubato::ResampleError),
    #[error("Symphonia probe/decode error: {0}")]
    Symphonia(#[from] SymphoniaError),
    #[error("Playback is locked (another track playing)")]
    PlaybackLocked,
    #[error("Invalid URL format: {0}")]
    InvalidUrl(String),
}

// Structure to hold playback requests passed through the channel
struct PlaybackRequest {
    url: String,
    channel_id: u32, // Channel where the request originated
}

#[tokio::main]
async fn main() -> Result<()> {
    // Setup tracing/logging subscriber
    tracing_subscriber::fmt::init();

    // --- Load Certificate and Key (using rustls) ---
    tracing::info!("Loading certificate from: {}", CERT_PATH);
    let certs = {
        let cert_file = File::open(CERT_PATH)
            .with_context(|| format!("Failed to open certificate file: {}", CERT_PATH))?;
        let mut reader = BufReader::new(cert_file);
        let certs = rustls_pemfile::certs(&mut reader)
            .map_err(|e| anyhow!("Failed to parse certificate: {}", e))?;
        certs
            .into_iter()
            .map(rustls::Certificate)
            .collect::<Vec<_>>()
    };
    if certs.is_empty() {
        return Err(anyhow!("No certificates found in {}", CERT_PATH));
    }

    tracing::info!("Loading private key from: {}", KEY_PATH);
    let key = {
        let key_file = File::open(KEY_PATH)
            .with_context(|| format!("Failed to open private key file: {}", KEY_PATH))?;
        let mut reader = BufReader::new(key_file);

        // Try both PKCS8 and RSA formats
        let key_der = match rustls_pemfile::pkcs8_private_keys(&mut reader) {
            Ok(keys) if !keys.is_empty() => keys[0].clone(),
            _ => {
                // Reset reader and try RSA format
                let mut reader = BufReader::new(File::open(KEY_PATH)?);
                match rustls_pemfile::rsa_private_keys(&mut reader) {
                    Ok(keys) if !keys.is_empty() => keys[0].clone(),
                    _ => return Err(anyhow!("No valid private key found in {}", KEY_PATH)),
                }
            }
        };

        rustls::PrivateKey(key_der)
    };
    tracing::info!("Certificate and key loaded successfully.");

    // Create TLS client configuration
    let mut root_store = rustls::RootCertStore::empty();
    // Optionally add webpki-roots for standard CA certificates
    // webpki_roots::TLS_SERVER_ROOTS.iter().for_each(|cert| {
    //     root_store.add(cert).unwrap();
    // });

    let tls_config = rustls::ClientConfig::builder()
        .with_safe_default_cipher_suites()
        .with_safe_default_kx_groups()
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(root_store)
        .with_single_cert(certs, key)
        .map_err(|e| BotError::Tls(format!("Failed to create TLS config: {}", e)))?;

    // --- Mumble Configuration ---
    tracing::info!(
        "Configuring Mumble client for {}@{}:{}",
        USERNAME,
        SERVER_ADDR,
        SERVER_PORT
    );
    let mut config = Config::new(SERVER_ADDR, SERVER_PORT)?
        .with_username(USERNAME)
        .with_tls_config(Arc::new(tls_config)); // Use the loaded TLS config

    if let Some(pw) = PASSWORD {
        config = config.with_password(pw);
    }

    // Configure audio: We want to *send* Opus, but not receive audio.
    config = config.with_audio(
        AudioRecvConfig::Disabled,
        AudioSendConfig::Enabled {
            codec: AudioCodec::Opus, // Standard Mumble codec
            frames_per_packet: 2,    // Common value, adjust based on server/network if needed
        },
    );
    tracing::info!(
        "Mumble audio configured for Opus output ({}Hz, {}ch target).",
        TARGET_SAMPLE_RATE,
        TARGET_CHANNELS
    );

    // --- Connect to Mumble ---
    tracing::info!("Connecting to Mumble server...");
    let (client, mut event_receiver) = MumbleClient::connect(config).await?;
    let client = Arc::new(client); // Wrap client in Arc for sharing across tasks
    tracing::info!("Connected successfully!");

    // --- Playback Queue and Handler Task ---
    let (play_tx, play_rx) = mpsc::channel::<PlaybackRequest>(32); // Channel for requests
    let playback_lock = Arc::new(Mutex::new(())); // Mutex to ensure sequential playback

    // Spawn the task that listens for playback requests and handles audio processing
    tokio::spawn(playback_handler(
        Arc::clone(&client),
        play_rx,
        Arc::clone(&playback_lock),
    ));

    // --- Main Event Loop ---
    tracing::info!("Entering main event loop. Waiting for messages or signals...");
    loop {
        tokio::select! {
            // Listen for incoming Mumble events
            Some(event_result) = event_receiver.recv() => {
                match event_result {
                    Ok(event) => {
                        // Clone necessary parts for potential async handling
                        let client_clone = Arc::clone(&client);
                        let play_tx_clone = play_tx.clone();

                        // Spawn a small task to handle each event asynchronously
                        // This prevents a slow handler from blocking the event receiver
                        tokio::spawn(async move {
                            if let Err(e) = handle_mumble_event(event, client_clone, play_tx_clone).await {
                                tracing::error!("Error handling Mumble event: {}", e);
                            }
                        });
                    }
                    Err(e) => {
                        tracing::error!("Error receiving Mumble event: {}", e);
                        if e.is_fatal() {
                            tracing::error!("Fatal Mumble error, shutting down.");
                            break; // Exit loop on fatal errors (e.g., network disconnect)
                        }
                        // Non-fatal errors might be logged but don't necessarily stop the bot
                    }
                }
            },
            // Listen for Ctrl+C signal for graceful shutdown
            _ = tokio::signal::ctrl_c() => {
                tracing::info!("Ctrl+C received, initiating shutdown...");
                break; // Exit the loop
            }
        }
    }

    // --- Disconnect Gracefully ---
    tracing::info!("Disconnecting from Mumble server...");
    // Drop the sender channel to signal the playback handler to stop
    drop(play_tx);
    // Attempt to disconnect cleanly
    if let Err(e) = client.disconnect().await {
        tracing::error!("Error during Mumble disconnect: {}", e);
    }
    tracing::info!("Disconnected. Application exiting.");
    Ok(())
}

// --- Mumble Event Handler ---
async fn handle_mumble_event(
    event: Event,
    client: Arc<MumbleClient>,
    play_tx: mpsc::Sender<PlaybackRequest>,
) -> Result<(), BotError> {
    match event {
        Event::TextMessage(msg) => {
            // Check if the message starts with our command prefix
            if msg.message.starts_with(PLAYBACK_COMMAND) {
                let url = msg.message[PLAYBACK_COMMAND.len()..].trim().to_string();
                if url.is_empty() {
                    tracing::warn!("Received empty !play command from actor {}", msg.actor);
                    // Optionally send a message back to the user/channel
                    let reply = "Please provide a YouTube URL after !play.";
                    // Send reply to the channel the message came from
                    if let Err(e) = client
                        .send_text_message_channel(msg.channel_id[0], reply)
                        .await
                    {
                        tracing::error!("Failed to send usage hint message: {}", e);
                    }
                    return Ok(());
                }

                tracing::info!(
                    "Received play command for URL: {} in channel {} from actor {}",
                    url,
                    msg.channel_id[0],
                    msg.actor
                );

                let request = PlaybackRequest {
                    url,
                    channel_id: msg.channel_id[0], // Assuming message is only sent to one channel
                };

                // Send the request to the playback handler task
                if let Err(e) = play_tx.send(request).await {
                    tracing::error!("Failed to send playback request to handler task: {}", e);
                    // Notify the channel about the internal error
                    let error_msg = "Internal error: Could not queue playback request.";
                    if let Err(send_err) = client
                        .send_text_message_channel(msg.channel_id[0], error_msg)
                        .await
                    {
                        tracing::error!("Failed to send queue error message: {}", send_err);
                    }
                }
            }
        }
        Event::Disconnected(reason) => {
            // This event is now handled by the is_fatal check in the main loop's error handling
            tracing::warn!("Received Disconnected event: {:?}", reason);
            // No action needed here as the main loop will break
        }
        Event::ServerSync(sync_info) => {
            tracing::info!(
                "ServerSync received (Session ID: {}, Channel ID: {})",
                sync_info.session,
                sync_info.channel_id
            );
            // Bot is now fully connected and synchronized.
            // Optional: Automatically join a specific channel upon connection
            // let target_channel_name = "Music";
            // if let Some(channel) = client.channels().find(|c| c.name == target_channel_name) {
            //     tracing::info!("Joining channel '{}' ({})", channel.name, channel.id);
            //     if let Err(e) = client.send_channel_state(Some(channel.id)).await {
            //         tracing::error!("Failed to join channel {}: {}", target_channel_name, e);
            //     }
            // } else {
            //     tracing::warn!("Could not find channel '{}' to join.", target_channel_name);
            // }
        }
        // Log other potentially useful events
        Event::UserConnected(state) => tracing::debug!("User connected: {}", state.name),
        Event::UserDisconnected(state) => tracing::debug!("User disconnected: {}", state.user),
        Event::UserUpdated(state) => tracing::debug!("User updated: {:?}", state.updates),
        // Add handlers for other events if needed
        _ => { /* Optional: trace ignored events: tracing::trace!("Ignored event: {:?}", event); */
        }
    }
    Ok(())
}

// --- Playback Handler Task ---
async fn playback_handler(
    client: Arc<MumbleClient>,
    mut play_rx: mpsc::Receiver<PlaybackRequest>,
    playback_lock: Arc<Mutex<()>>,
) {
    tracing::info!("Playback handler task started.");
    while let Some(request) = play_rx.recv().await {
        let lock = Arc::clone(&playback_lock);
        let client_clone = Arc::clone(&client);

        // Spawn a new task for each playback attempt
        tokio::spawn(async move {
            // --- Acquire Playback Lock ---
            // Attempt to acquire the lock immediately
            let _guard = match lock.try_lock() {
                Ok(guard) => guard,
                Err(_) => {
                    tracing::warn!(
                        "Playback lock held, rejecting request for '{}'. Another track is playing.",
                        request.url
                    );
                    // Send a message that the bot is busy
                    let busy_msg = "Sorry, I'm currently playing another track. Please wait.";
                    if let Err(e) = client_clone
                        .send_text_message_channel(request.channel_id, busy_msg)
                        .await
                    {
                        tracing::error!("Failed to send 'bot busy' message: {}", e);
                    }
                    return;
                }
            };

            tracing::info!(
                "Acquired playback lock. Starting playback for URL: {}",
                request.url
            );
            // Notify channel playback is starting
            let start_msg = format!("Playing: {}", request.url);
            if let Err(e) = client_clone
                .send_text_message_channel(request.channel_id, &start_msg)
                .await
            {
                tracing::error!("Failed to send 'playback starting' message: {}", e);
            }

            // --- Execute Playback ---
            match play_youtube_audio(&client_clone, &request.url, request.channel_id).await {
                Ok(_) => {
                    tracing::info!("Finished playback successfully for URL: {}", request.url);
                    // Notify channel playback finished
                    let finish_msg = format!("Finished: {}", request.url);
                    if let Err(e) = client_clone
                        .send_text_message_channel(request.channel_id, &finish_msg)
                        .await
                    {
                        tracing::error!("Failed to send 'playback finished' message: {}", e);
                    }
                }
                Err(e) => {
                    tracing::error!("Error during playback of {}: {}", request.url, e);
                    // Notify channel about the error
                    let error_msg = format!("Error playing {}: {}", request.url, e);
                    if let Err(send_err) = client_clone
                        .send_text_message_channel(request.channel_id, &error_msg)
                        .await
                    {
                        tracing::error!("Failed to send playback error message: {}", send_err);
                    }
                }
            }
            tracing::info!("Released playback lock for URL: {}", request.url);
        });
    }
    tracing::info!("Playback handler task finished (channel closed).");
}

// --- YouTube Download, Audio Decoding, Resampling, and Playback ---
async fn play_youtube_audio(
    client: &MumbleClient,
    url: &str,
    channel_id: u32,
) -> Result<(), BotError> {
    // --- 1. Get YouTube Audio Stream ---
    tracing::debug!("Fetching video info for URL: {}", url);
    let id = Id::from_raw(url).map_err(|e| BotError::InvalidUrl(e.to_string()))?;
    let video = Video::from_id(id.into_owned())
        .await
        .map_err(|e| BotError::YouTube(format!("Failed to get video info: {}", e)))?;

    // Find the best audio-only stream
    let stream = video
        .streams()
        .iter()
        .filter(|s| s.includes_audio_track && !s.includes_video_track)
        .max_by_key(|s| {
            // Prioritize quality/bitrate
            let quality_score = match s.quality_label.as_ref().map(|q| q.as_str()) {
                Some("AUDIO_QUALITY_HIGH") => 3,
                Some("AUDIO_QUALITY_MEDIUM") => 2,
                Some("AUDIO_QUALITY_LOW") => 1,
                _ => 0,
            };
            (quality_score, s.bitrate.unwrap_or(0))
        })
        .ok_or_else(|| BotError::YouTube("No suitable audio-only stream found".to_string()))?;

    tracing::info!(
        "Selected audio stream: Quality={}, Bitrate={:?}, Type={}",
        stream.quality_label.as_ref().map_or("N/A", |q| q.as_str()),
        stream.bitrate,
        stream.mime.essence_str(),
    );

    // --- 2. Download Audio to Temporary File ---
    let temp_dir = std::env::temp_dir().join("mumble_bot_audio");
    tokio::fs::create_dir_all(&temp_dir).await?;
    let temp_filename = format!("audio_{}.tmp", rand::random::<u64>());
    let file_path = temp_dir.join(&temp_filename);

    tracing::debug!("Downloading audio to temporary file: {:?}", file_path);
    stream
        .download_to(&file_path)
        .await
        .map_err(|e| BotError::YouTube(format!("Failed to download audio: {}", e)))?;
    tracing::debug!("Temporary file download complete.");

    // --- 3. Decode and Resample using Symphonia ---
    struct TempFileGuard(PathBuf);
    impl Drop for TempFileGuard {
        fn drop(&mut self) {
            tracing::debug!("Cleaning up temporary file: {:?}", self.0);
            if let Err(e) = std::fs::remove_file(&self.0) {
                tracing::warn!("Failed to remove temporary file {:?}: {}", self.0, e);
            }
        }
    }
    let _file_guard = TempFileGuard(file_path.clone());

    let source = Box::new(File::open(&file_path)?);
    let mss = MediaSourceStream::new(source, Default::default());
    let hint = Hint::new();

    let meta_opts: MetadataOptions = Default::default();
    let fmt_opts: FormatOptions = Default::default();

    tracing::debug!("Probing audio format...");
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &fmt_opts, &meta_opts)
        .map_err(|e| BotError::AudioProcessing(format!("Symphonia probe failed: {}", e)))?;

    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL && t.codec_params.sample_rate.is_some())
        .ok_or_else(|| BotError::AudioProcessing("No supported audio track found".to_string()))?;

    let dec_opts: DecoderOptions = Default::default();
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &dec_opts)
        .map_err(|e| {
            BotError::AudioProcessing(format!("Symphonia decoder creation failed: {}", e))
        })?;

    let track_id = track.id;
    let input_spec = track.codec_params.clone();
    let input_sample_rate = input_spec.sample_rate.unwrap();
    let input_channels = input_spec
        .channels
        .ok_or_else(|| BotError::AudioProcessing("Missing channel info".to_string()))?
        .count();

    tracing::info!(
        "Decoded audio track: Sample Rate={}Hz, Channels={}",
        input_sample_rate,
        input_channels
    );

    // --- 4. Setup Resampler (if needed) ---
    let mut resampler: Option<SincFixedIn<f32>> = None;
    if input_sample_rate != TARGET_SAMPLE_RATE || input_channels != TARGET_CHANNELS {
        tracing::info!(
            "Resampling required: Input {}Hz/{}ch -> Target {}Hz/{}ch",
            input_sample_rate,
            input_channels,
            TARGET_SAMPLE_RATE,
            TARGET_CHANNELS
        );

        // Create resampler
        resampler = Some(SincFixedIn::<f32>::new(
            TARGET_SAMPLE_RATE as f64 / input_sample_rate as f64,
            2.0,
            &rubato::SincInterpolationParameters {
                sinc_len: 128,
                f_cutoff: 0.95,
                oversampling_factor: 128,
                interpolation: rubato::SincInterpolationType::Linear,
                window: WindowFunction::BlackmanHarris2,
            },
            1024,
            input_channels,
            TARGET_CHANNELS,
        )?);
    } else {
        tracing::info!("Input audio matches target format. No resampling needed.");
    }

    // --- 5. Audio Processing and Sending Loop ---
    let audio_output = client.audio();
    // Mumble Opus typically uses 10, 20, 40, or 60 ms frames
    let frame_duration_ms = 20;
    let frame_size = (TARGET_SAMPLE_RATE as usize / (1000 / frame_duration_ms)) * TARGET_CHANNELS;
    tracing::debug!(
        "Using Mumble frame size: {} samples ({} ms)",
        frame_size,
        frame_duration_ms
    );

    // Buffers for processing
    let mut sample_buf_i16 = SampleBuffer::<i16>::new(
        frame_size as u64,
        SignalSpec::new(TARGET_SAMPLE_RATE, symphonia::core::audio::Layout::Mono),
    );

    // Buffers for Rubato
    let mut resampler_in_buf: Vec<Vec<f32>> = vec![Vec::with_capacity(2048); input_channels];
    let mut resampler_out_buf: Vec<Vec<f32>> = vec![Vec::with_capacity(4096); TARGET_CHANNELS];

    'decode_loop: loop {
        match format.next_packet() {
            Ok(packet) => {
                // Only process packets belonging to the selected audio track
                if packet.track_id() != track_id {
                    continue;
                }

                match decoder.decode(&packet) {
                    Ok(decoded_buf_ref) => {
                        // --- Convert decoded buffer to f32 for processing ---
                        // Create a new f32 buffer with appropriate specs
                        let mut f32_buffer = match decoded_buf_ref {
                            AudioBufferRef::F32(buf) => buf.clone(),
                            AudioBufferRef::S32(buf) => {
                                let mut f32_buf =
                                    AudioBuffer::<f32>::new(buf.capacity() as u64, *buf.spec());
                                for (i, &sample) in buf.chan(0).iter().enumerate() {
                                    f32_buf.chan_mut(0)[i] = sample as f32 / i32::MAX as f32;
                                }
                                f32_buf
                            }
                            AudioBufferRef::S16(buf) => {
                                let mut f32_buf =
                                    AudioBuffer::<f32>::new(buf.capacity() as u64, *buf.spec());
                                for (i, &sample) in buf.chan(0).iter().enumerate() {
                                    f32_buf.chan_mut(0)[i] = sample as f32 / i16::MAX as f32;
                                }
                                f32_buf
                            }
                            _ => {
                                tracing::warn!("Unsupported audio format, skipping packet");
                                continue;
                            }
                        };

                        let num_decoded_frames = f32_buffer.frames();

                        // --- Prepare input for Resampler ---
                        for chan_buf in resampler_in_buf.iter_mut() {
                            chan_buf.clear();
                            chan_buf.reserve(num_decoded_frames);
                        }

                        // Deinterleave into the resampler input buffer
                        for frame in 0..num_decoded_frames {
                            for chan in 0..input_channels {
                                resampler_in_buf[chan].push(f32_buffer.chan(chan)[frame]);
                            }
                        }

                        // --- Resample OR Passthrough ---
                        let output_samples_f32: &Vec<Vec<f32>> =
                            if let Some(resampler) = resampler.as_mut() {
                                // Clear reusable output buffer
                                for chan_buf in resampler_out_buf.iter_mut() {
                                    chan_buf.clear();
                                }

                                // Process with resampler
                                let num_output =
                                    resampler.process(&resampler_in_buf, &mut resampler_out_buf)?;

                                // Trim to actual size
                                for chan_buf in resampler_out_buf.iter_mut() {
                                    chan_buf.truncate(num_output);
                                }
                                &resampler_out_buf
                            } else {
                                // No resampling needed
                                &resampler_in_buf
                            };

                        let num_output_frames = output_samples_f32.get(0).map_or(0, |v| v.len());
                        if num_output_frames == 0 {
                            continue;
                        }

                        // --- Convert to Target Format (PCM i16 Interleaved) ---
                        // Ensure buffer is large enough
                        let required_i16_samples = num_output_frames * TARGET_CHANNELS;

                        // Interleave and convert f32 [-1.0, 1.0] to i16
                        let samples_i16 = sample_buf_i16.samples_mut();
                        for frame_idx in 0..num_output_frames {
                            for chan_idx in 0..TARGET_CHANNELS {
                                let input_chan_idx = if input_channels == TARGET_CHANNELS {
                                    chan_idx // Direct mapping
                                } else if TARGET_CHANNELS == 1 && input_channels > 1 {
                                    // Mix or take first channel for mono output
                                    0
                                    // Alternative mix: (output_samples_f32[0][frame_idx] + output_samples_f32[1][frame_idx]) * 0.5
                                } else {
                                    // Default case
                                    0
                                };

                                let sample_f32 = output_samples_f32[input_chan_idx][frame_idx];
                                // Clamp and scale
                                let sample_idx = frame_idx * TARGET_CHANNELS + chan_idx;
                                if sample_idx < samples_i16.len() {
                                    samples_i16[sample_idx] =
                                        (sample_f32.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
                                }
                            }
                        }

                        // --- Send to Mumble in Chunks ---
                        let final_samples_i16 = &samples_i16[..num_output_frames * TARGET_CHANNELS];
                        for chunk in final_samples_i16.chunks(frame_size) {
                            if !chunk.is_empty() {
                                // send_frame_slice expects &[i16]
                                if let Err(e) = audio_output.send_frame_slice(chunk).await {
                                    tracing::error!("Failed to send audio frame to Mumble: {}", e);
                                    return Err(BotError::Mumble(e));
                                }
                                // Small delay to pace sending (optional)
                                tokio::time::sleep(Duration::from_millis(1)).await;
                            }
                        }
                    }
                    Err(SymphoniaError::DecodeError(e)) => {
                        // Usually recoverable, just log and continue
                        tracing::warn!("Symphonia decode error (recoverable): {}", e);
                    }
                    Err(e) => {
                        // Unrecoverable decode error for this stream
                        tracing::error!("Symphonia unrecoverable decoder error: {}", e);
                        return Err(BotError::Symphonia(e));
                    }
                }
            }
            Err(SymphoniaError::IoError(ref err))
                if err.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                tracing::info!("Reached end of audio stream (EOF).");
                break 'decode_loop; // Expected end of file/stream
            }
            Err(SymphoniaError::ResetRequired) => {
                // This indicates a discontinuity or change requiring decoder reset
                tracing::warn!("Decoder reset required, stopping playback for this track.");
                break 'decode_loop;
            }
            Err(e) => {
                tracing::error!("Symphonia error reading next packet: {}", e);
                return Err(BotError::Symphonia(e));
            }
        }
        // Yield CPU briefly to allow other tasks to run
        tokio::task::yield_now().await;
    }

    // The temporary file is cleaned up by the _file_guard going out of scope
    tracing::debug!("Finished processing and sending audio for {}", url);
    Ok(())
}
