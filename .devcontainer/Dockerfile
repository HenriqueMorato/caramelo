# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

ARG CURL_IMPERSONATE_VERSION=2.1.1
ARG NODE_VERSION=24.19.0
ARG BUNDLER_VERSION=4.0.19
ARG TARGETARCH

USER root

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libvips sqlite3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Keep this version and its checksums aligned with the production Dockerfile.
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
    chmod 0755 /usr/local/bin/curl-impersonate /usr/local/bin/curl_chrome146; \
    rm "/tmp/${filename}"

COPY vendor/licenses/curl-impersonate-MIT.txt /usr/share/doc/curl-impersonate/LICENSE

# A named volume is mounted here by Compose; seed it with the dev user's ownership.
RUN mkdir -p /workspaces/local_folio/vendor/bundle && \
    chown -R vscode:vscode /workspaces/local_folio/vendor

USER vscode

# Match the Bundler version recorded in Gemfile.lock to keep setup deterministic.
RUN /home/vscode/.local/bin/mise exec ruby@${RUBY_VERSION} -- \
    env PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}" \
    gem install bundler --no-document --version "$BUNDLER_VERSION"

RUN /home/vscode/.local/bin/mise use --global node@${NODE_VERSION}

# Bind Rails outside the container and expose mise-managed tools to non-interactive commands.
ENV BINDING="0.0.0.0" \
    PATH="/home/vscode/.local/share/mise/shims:/home/vscode/.local/bin:${PATH}"
