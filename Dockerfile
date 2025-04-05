FROM elixir:1.15

# Install yt-dlp and Python
RUN apt-get update && \
    apt-get install -y python3 python3-pip && \
    pip3 install --break-system-packages --no-cache-dir yt-dlp && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Elixir project files
COPY . .

# Install and build Elixir dependencies
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix compile

# Start the app
CMD ["mix", "run", "--no-halt"]
