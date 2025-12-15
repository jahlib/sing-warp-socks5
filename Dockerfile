FROM alpine:latest

# Install required packages
RUN apk add --no-cache wget tar ca-certificates

# Set working directory
WORKDIR /app

# Download and extract sing-box
RUN wget https://github.com/shtorm-7/sing-box-extended/releases/download/v1.12.12-extended-1.5.1/sing-box-1.12.12-extended-1.5.1-linux-amd64.tar.gz && \
    tar -xzf sing-box-1.12.12-extended-1.5.1-linux-amd64.tar.gz && \
    mv sing-box-1.12.12-extended-1.5.1-linux-amd64/sing-box /usr/local/bin/sing-box && \
    chmod +x /usr/local/bin/sing-box && \
    rm -rf sing-box-1.12.12-extended-1.5.1-linux-amd64.tar.gz sing-box-1.12.12-extended-1.5.1-linux-amd64

# Copy configuration generator script
COPY generate-config.sh /app/generate-config.sh
RUN chmod +x /app/generate-config.sh

# Copy warp configuration
COPY warp.conf /app/warp.conf

# Expose SOCKS5 proxy port
EXPOSE 2080

# Generate config and run sing-box
CMD ["/bin/sh", "-c", "/app/generate-config.sh && sing-box run -c /app/config.json"]
