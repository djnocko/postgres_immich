FROM postgres:16-bookworm

# Install build dependencies and PostGIS
RUN apt-get update && apt-get install -y \
    postgresql-16-postgis-3 \
    postgresql-16-postgis-3-scripts \
    postgresql-server-dev-16 \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install pgvector
RUN git clone --branch v0.7.4 https://github.com/pgvector/pgvector.git /tmp/pgvector && \
    cd /tmp/pgvector && \
    make && make install && \
    rm -rf /tmp/pgvector

# Copy initialization script to enable extensions
COPY init-extensions.sh /docker-entrypoint-initdb.d/init-extensions.sh

# Ensure the script is executable
RUN chmod +x /docker-entrypoint-initdb.d/init-extensions.sh