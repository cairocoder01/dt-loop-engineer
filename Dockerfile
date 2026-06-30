FROM alpine:3.19

# Runtime dependencies: PHP 8.2, Node, Git, GitHub CLI, Chromium, Composer
RUN apk add --no-cache \
    bash curl git jq \
    unzip rsync \
    github-cli \
    nodejs npm \
    php82 \
    php82-curl \
    php82-dom \
    php82-mbstring \
    php82-xml \
    php82-xmlwriter \
    php82-tokenizer \
    php82-pdo_mysql \
    php82-session \
    php82-zip \
    php82-opcache \
    chromium \
    nss freetype harfbuzz ca-certificates ttf-freefont

# PHP alias (Alpine names it php82)
RUN ln -s /usr/bin/php82 /usr/local/bin/php

# Composer
RUN curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

# WP-CLI (installed at runtime by bootstrap hook, but pre-download here for cache)
RUN curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# opencode CLI (AI agent runner)
# Package name: opencode-ai on npm (binary available as `opencode`).
# If the build fails here with "opencode: not found", verify the package name
# at https://www.npmjs.com/search?q=opencode before changing it.
RUN npm install -g opencode-ai \
    && opencode --version

# Playwright MCP for browser automation (used by opencode during stage 02)
RUN npm install -g @playwright/mcp

# Playwright Node.js library for the E2E verify stage (03_chrome_mcp_e2e.js).
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD skips the bundled browser download; we use
# the system Chromium (installed above) via CHROME_BIN at runtime instead.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install -g playwright

# Browser env vars for Playwright/Puppeteer inside Alpine
ENV CHROME_BIN=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/bin

WORKDIR /workspace
COPY . /workspace/

# Make all shell scripts executable
RUN find /workspace -name "*.sh" -exec chmod +x {} \;

# State directory for per-issue artifacts
RUN mkdir -p /workspace/state

ENTRYPOINT ["/bin/bash", "/workspace/core-runner.sh"]
