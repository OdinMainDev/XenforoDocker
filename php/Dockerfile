FROM php:8.2-fpm

RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libzip-dev \
    libicu-dev \
    libmagickwand-dev

# Configure and install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure intl \
    && docker-php-ext-install mysqli pdo_mysql opcache curl gd zip intl exif

# Install Imagick via PECL
RUN pecl install imagick \
    && docker-php-ext-enable imagick

# Create log directory for PHP-FPM
RUN mkdir -p /var/log/php && chown -R www-data:www-data /var/log/php

# Create www-data user with proper UID/GID
RUN groupmod -g 1000 www-data \
    && usermod -u 1000 -g 1000 www-data

# Set working directory
WORKDIR /var/www/html

# Copy custom PHP configuration
COPY php.ini /usr/local/etc/php/php.ini
COPY pool.conf /usr/local/etc/php-fpm.d/www.conf

# Set proper permissions
RUN chown -R www-data:www-data /var/www/html

USER www-data

EXPOSE 9000

CMD ["php-fpm"]