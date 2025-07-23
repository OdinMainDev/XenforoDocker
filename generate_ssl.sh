#!/bin/bash

# SSL certificate generation script for onion service
# This script generates self-signed certificates for the onion service

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SSL_DIR="./nginx/ssl"
CERT_FILE="$SSL_DIR/onion.crt"
KEY_FILE="$SSL_DIR/onion.key"
DAYS=3650  # 10 years

echo -e "${YELLOW}Starting SSL certificate generation for onion service...${NC}"

# Create SSL directory if it doesn't exist
if [ ! -d "$SSL_DIR" ]; then
    echo -e "${YELLOW}Creating SSL directory: $SSL_DIR${NC}"
    mkdir -p "$SSL_DIR"
fi

# Check if certificates already exist
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo -e "${YELLOW}SSL certificates already exist. Do you want to regenerate them? (y/N)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Using existing certificates.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}Regenerating certificates...${NC}"
fi

# Generate private key
echo -e "${YELLOW}Generating private key...${NC}"
openssl genrsa -out "$KEY_FILE" 4096

# Generate certificate signing request and certificate
echo -e "${YELLOW}Generating self-signed certificate...${NC}"
openssl req -new -x509 -key "$KEY_FILE" -out "$CERT_FILE" -days $DAYS \
    -subj "/C=XX/ST=Anonymous/L=Anonymous/O=Anonymous/OU=Anonymous/CN=*.onion" \
    -extensions v3_req \
    -config <(
        echo '[req]'
        echo 'distinguished_name = req_distinguished_name'
        echo 'req_extensions = v3_req'
        echo 'prompt = no'
        echo '[req_distinguished_name]'
        echo 'C = XX'
        echo 'ST = Anonymous'
        echo 'L = Anonymous'
        echo 'O = Anonymous'
        echo 'OU = Anonymous'
        echo 'CN = *.onion'
        echo '[v3_req]'
        echo 'keyUsage = keyEncipherment, dataEncipherment'
        echo 'extendedKeyUsage = serverAuth'
        echo 'subjectAltName = @alt_names'
        echo '[alt_names]'
        echo 'DNS.1 = *.onion'
    )

# Set proper permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Verify certificates
echo -e "${YELLOW}Verifying generated certificates...${NC}"
if openssl x509 -in "$CERT_FILE" -text -noout > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Certificate is valid${NC}"
else
    echo -e "${RED}✗ Certificate validation failed${NC}"
    exit 1
fi

if openssl rsa -in "$KEY_FILE" -check -noout > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Private key is valid${NC}"
else
    echo -e "${RED}✗ Private key validation failed${NC}"
    exit 1
fi

# Display certificate information
echo -e "${YELLOW}Certificate Information:${NC}"
echo "Subject: $(openssl x509 -in "$CERT_FILE" -subject -noout | sed 's/subject=//')"
echo "Issuer: $(openssl x509 -in "$CERT_FILE" -issuer -noout | sed 's/issuer=//')"
echo "Valid from: $(openssl x509 -in "$CERT_FILE" -startdate -noout | sed 's/notBefore=//')"
echo "Valid until: $(openssl x509 -in "$CERT_FILE" -enddate -noout | sed 's/notAfter=//')"
echo "Fingerprint: $(openssl x509 -in "$CERT_FILE" -fingerprint -sha256 -noout | sed 's/SHA256 Fingerprint=//')"

echo -e "${GREEN}✓ SSL certificates generated successfully!${NC}"
echo -e "${YELLOW}Files created:${NC}"
echo "  - Certificate: $CERT_FILE"
echo "  - Private key: $KEY_FILE"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Start the Tor service: docker compose -f docker-compose.web.yml up -d tor"
echo "2. Wait for onion address generation"
echo "3. Get your onion address: docker exec xenforo_tor cat /var/lib/tor/hidden_service/hostname"
echo "4. Restart nginx to load SSL certificates"
echo
echo -e "${GREEN}Your onion service will be accessible via both HTTP and HTTPS!${NC}"