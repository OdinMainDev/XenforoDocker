# XenForo Docker Setup with Tor Hidden Service

A comprehensive Docker setup for running XenForo forum with enhanced security features including Tor hidden service support, fail2ban protection, and Cloudflare integration.

## Features

- **XenForo Forum**: Complete forum setup with PHP-FPM and Nginx
- **Tor Hidden Service**: Anonymous access via .onion domain with HTTP/HTTPS support
- **Security**: Fail2ban protection, rate limiting, security headers
- **Cloudflare Integration**: Real IP detection and optimized configuration
- **SSL Support**: Self-signed certificates for onion service
- **Database**: MySQL with optimized configuration and backup scripts

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- Domain name configured with Cloudflare (for clearnet access)
- Basic understanding of Docker and Linux administration

### Installation

1. **Clone and Setup**
   ```bash
   git clone <repository-url>
   cd XenforoDocker
   ```

2. **Environment Configuration**
   ```bash
   cp .env.example .env
   # Edit .env file with your configuration
   ```

3. **Generate SSL Certificates**
   ```bash
   ./generate_ssl.sh
   ```

4. **Start Services**
   ```bash
   # Start database
   docker compose -f docker-compose.db.yml up -d
   
   # Start web services
   docker compose -f docker-compose.web.yml up -d
   ```

5. **Get Your Onion Address**
   ```bash
   docker exec xenforo_tor cat /var/lib/tor/hidden_service/hostname
   ```

## Directory Structure

```
├── docker-compose.web.yml          # Web services configuration
├── docker-compose.db.yml           # Database configuration
├── generate_ssl.sh                 # SSL certificate generation script
├── nginx/
│   └── conf.d/
│       ├── xenforo.conf            # Main site configuration
│       ├── xenforo_onion.conf      # Onion service configuration
│       ├── rate-limit.conf         # Rate limiting rules
│       ├── log-formats.conf        # Custom log formats
│       └── server-names.conf       # Server names configuration
├── php/
│   ├── Dockerfile                  # PHP-FPM container build
│   ├── php.ini                     # PHP configuration
│   └── pool.conf                   # PHP-FPM pool configuration
├── tor/
│   ├── torrc                       # Tor configuration
│   └── keys/                       # Tor hidden service keys
├── mysql/
│   └── conf.d/
│       └── security.cnf            # MySQL security configuration
├── logs/                           # Application logs
├── scripts/
│   └── backup.sh                   # Database backup script
└── xenforo_app/                    # XenForo application files
```

## Configuration

### Environment Variables

Key environment variables in `.env`:

```bash
# Database
MYSQL_ROOT_PASSWORD=your_secure_password
MYSQL_DATABASE=xenforo
MYSQL_USER=xenforo_user
MYSQL_PASSWORD=xenforo_password

# PHP
PHP_MEMORY_LIMIT=256M
PHP_MAX_EXECUTION_TIME=300
PHP_POST_MAX_SIZE=50M
PHP_UPLOAD_MAX_FILESIZE=50M

# Timezone
TZ=UTC
```

### Tor Hidden Service Setup

**Before starting Tor service, set correct permissions:**

```bash
sudo chown -R 0:0 ./tor/keys
sudo chmod 700 ./tor/keys
sudo chmod 600 ./tor/keys/*
```

The setup automatically creates a Tor hidden service accessible via:
- HTTP: `http://your_onion_address.onion`
- HTTPS: `https://your_onion_address.onion` (self-signed certificate)

To use existing Tor keys:
1. Place your `hostname`, `hs_ed25519_public_key`, and `hs_ed25519_secret_key` files in `./tor/keys/`
2. Set correct permissions as shown above
3. Restart Tor service: `docker compose -f docker-compose.web.yml restart tor`

### Database Import

To load your existing database:

```bash
# Copy database dump to server
# Then copy to Docker container
docker cp ./database_dump.sql xenforo_mysql:/tmp/database_dump.sql

# Recreate database (clears old data)
docker exec -i xenforo_mysql mysql -u root -p -e "DROP DATABASE IF EXISTS xenforo; CREATE DATABASE xenforo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Import dump into database
docker exec -i xenforo_mysql mysql -u root -p xenforo -e "source /tmp/database_dump.sql"

# Verify import
docker exec -i xenforo_mysql mysql -u root -p xenforo -e "SHOW TABLES;"

# Clean up
docker exec xenforo_mysql rm /tmp/database_dump.sql
```

### Nginx Configuration

#### Main Site (Cloudflare)
- Configured for Cloudflare proxy
- Real IP detection via `CF-Connecting-IP` header
- Security headers and SSL optimization
- Rate limiting for login attempts

#### Onion Service
- Dedicated configuration for .onion domain
- HTTP and HTTPS support
- Optimized for Tor Browser
- Separate logging for onion traffic

### Security Features

#### Rate Limiting
- Login attempts: 1 request per second, burst of 5
- Configurable via `nginx/conf.d/rate-limit.conf`

#### Security Headers
- Content Security Policy
- HSTS for HTTPS
- XSS Protection
- Content Type Options
- Frame Options

#### Fail2ban Protection
- Monitors nginx access logs
- Automatically bans malicious IPs
- Supports both clearnet and onion logs
- Cloudflare IP detection

## Management Commands

### Service Management
```bash
# Start all services
docker compose -f docker-compose.db.yml -f docker-compose.web.yml up -d

# Stop all services
docker compose -f docker-compose.db.yml -f docker-compose.web.yml down

# View logs
docker logs xenforo_nginx
docker logs xenforo_php
docker logs xenforo_tor
```

### Database Management
```bash
# Backup database
./scripts/backup.sh

# Access MySQL
docker exec -it xenforo_mysql mysql -u root -p
```

### SSL Certificate Management
```bash
# Generate new certificates
./generate_ssl.sh

# View certificate details
openssl x509 -in nginx/ssl/onion.crt -text -noout
```

### Tor Service Management
```bash
# Get onion address
docker exec xenforo_tor cat /var/lib/tor/hidden_service/hostname

# View Tor logs
docker logs xenforo_tor

# Restart Tor with new keys
docker compose -f docker-compose.web.yml restart tor
```

## Monitoring and Logs

### Log Files
- **Nginx Access**: `logs/nginx/xenforo_access.log`
- **Nginx Onion**: `logs/nginx/onion_access.log`
- **Nginx Errors**: `logs/nginx/xenforo_error.log`
- **PHP Errors**: `logs/php/error.log`
- **Tor Logs**: Available via `docker logs xenforo_tor`

### Log Retention
- Nginx logs are automatically trimmed to the `NGINX_LOG_MAX_SIZE_MB` limit (default 500 MB) by the backup service.
- Adjust the limit in `.env` if you need a different cap or disable the mount if you want to manage retention manually.

### Health Checks
```bash
# Check all services status
docker compose -f docker-compose.web.yml ps

# Test nginx configuration
docker exec xenforo_nginx nginx -t

# Test onion connectivity (requires Tor proxy)
curl --socks5-hostname 127.0.0.1:9050 http://your_onion.onion
```

## Security Considerations

### Server Security
1. **Firewall**: Only allow necessary ports (80, 443, 22)
2. **SSH**: Use key authentication, disable password login
3. **Updates**: Keep system and Docker images updated
4. **Monitoring**: Monitor logs for suspicious activity

### Cloudflare Configuration
1. **SSL Mode**: Use "Full (Strict)" SSL mode
2. **IP Whitelisting**: Consider restricting access to Cloudflare IPs only
3. **DDoS Protection**: Enable Cloudflare's DDoS protection
4. **Bot Fight Mode**: Enable for additional protection

### Tor Security
1. **Key Management**: Securely backup Tor private keys
2. **Access Control**: Monitor onion service access logs
3. **Updates**: Keep Tor updated to latest version
4. **Anonymity**: Never reveal connection between clearnet and onion sites

## Troubleshooting

### Common Issues

#### Tor Service Won't Start
```bash
# Check Tor logs
docker logs xenforo_tor

# Verify key file permissions
ls -la ./tor/keys/
sudo chown -R 0:0 ./tor/keys
sudo chmod 700 ./tor/keys && sudo chmod 600 ./tor/keys/*
```

#### Nginx Configuration Errors
```bash
# Test configuration
docker exec xenforo_nginx nginx -t

# Check specific error
docker logs xenforo_nginx
```

#### Database Connection Issues
```bash
# Check database status
docker compose -f docker-compose.db.yml ps

# Test connection
docker exec xenforo_mysql mysql -u root -p -e "SHOW DATABASES;"
```

#### SSL Certificate Issues
```bash
# Regenerate certificates
./generate_ssl.sh

# Verify certificate
openssl x509 -in nginx/ssl/onion.crt -text -noout
```

### Performance Optimization

#### PHP-FPM Tuning
Edit `php/pool.conf`:
```ini
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
```

#### MySQL Optimization
Edit `mysql/conf.d/security.cnf`:
```ini
innodb_buffer_pool_size = 1G
query_cache_size = 64M
tmp_table_size = 64M
max_heap_table_size = 64M
```

#### Nginx Caching
Add to nginx configuration:
```nginx
location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

## Backup and Recovery

### Database Backup
```bash
# Automated backup (run via cron)
./scripts/backup.sh

# Manual backup
docker exec xenforo_mysql mysqldump -u root -p xenforo > backup.sql
```

Set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `.env` to push each compressed backup to Telegram automatically. The script retains local archives only when delivery is skipped or fails. Optional overrides: `TELEGRAM_THREAD_ID` for forum topics and `TELEGRAM_MESSAGE_PREFIX` for the caption start.

Backups are exported as password-protected ZIP archives. Configure `BACKUP_ARCHIVE_PASSWORD` in `.env` (required) so the script can encrypt the archive before uploading or storing it.

### Configuration Backup
```bash
# Backup entire configuration
tar -czf xenforo-config-$(date +%Y%m%d).tar.gz \
  nginx/ php/ tor/ mysql/ docker-compose*.yml .env
```

### Tor Keys Backup
```bash
# Backup Tor keys (KEEP SECURE!)
tar -czf tor-keys-$(date +%Y%m%d).tar.gz tor/keys/
```

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For support and questions:
- Create an issue in the repository
- Check existing documentation and troubleshooting guides
- Review Docker and XenForo official documentation

## Disclaimer

This setup is provided as-is for educational and legitimate purposes. Users are responsible for:
- Complying with local laws and regulations
- Securing their installations properly
- Maintaining and updating their systems
- Using Tor services responsibly and legally

The authors are not responsible for any misuse or illegal activities conducted with this software.
