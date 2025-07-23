FROM elixir:1.15-alpine

# Install build dependencies
RUN apk add --no-cache build-base git

# Set working directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files (sem o mix.lock por enquanto)
COPY mix.exs ./

# Install dependencies
RUN mix deps.get && mix deps.compile

# Copy application code
COPY . .

# Compile the application
RUN mix compile

# Expose port
EXPOSE 4000

# Start the application
CMD ["mix", "phx.server"]