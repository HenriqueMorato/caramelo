# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. For the complete
# self-hosted stack, including Solid Queue, run: docker compose up --build

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.7
ARG CURL_IMPERSONATE_VERSION=2.1.1
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y bash ca-certificates curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Download the browser-compatible HTTP transport used for Yahoo Finance quotes.
FROM base AS market-data-transport
ARG CURL_IMPERSONATE_VERSION
ARG TARGETARCH

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) \
        archive="x86_64-linux-gnu"; \
        checksum="29972a063db87a6697f1273706d63f47bfe947ef4245391096b60f0ca8b53ad3" \
        ;; \
      arm64) \
        archive="aarch64-linux-gnu"; \
        checksum="69087a501ec2fb2111dc0af1df2d82c1bf7880b3bad5c1c90a0c62eba57c587e" \
        ;; \
      *) \
        echo "Unsupported Docker architecture: $TARGETARCH" >&2; \
        exit 1 \
        ;; \
    esac; \
    filename="curl-impersonate-v${CURL_IMPERSONATE_VERSION}.${archive}.tar.gz"; \
    curl --fail --location --show-error --silent \
      "https://github.com/lexiforest/curl-impersonate/releases/download/v${CURL_IMPERSONATE_VERSION}/${filename}" \
      --output "/tmp/${filename}"; \
    echo "${checksum}  /tmp/${filename}" | sha256sum --check -; \
    tar --extract --gzip --file "/tmp/${filename}" --directory /usr/local/bin \
      curl-impersonate curl_chrome146; \
    chmod 0755 /usr/local/bin/curl-impersonate /usr/local/bin/curl_chrome146

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

COPY --from=market-data-transport /usr/local/bin/curl-impersonate /usr/local/bin/curl-impersonate
COPY --from=market-data-transport /usr/local/bin/curl_chrome146 /usr/local/bin/curl_chrome146
COPY vendor/licenses/curl-impersonate-MIT.txt /usr/share/doc/curl-impersonate/LICENSE

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the application secret and database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
