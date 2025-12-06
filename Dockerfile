# Multi-stage Dockerfile for Laravel Production with PHP 8.4-FPM + Nginx
# Optimized for CapRover deployment

# ============================================
# Stage 1: PHP Dependencies
# ============================================
FROM composer:2 AS composer

# Install system dependencies and PHP extensions needed by Laravel packages
RUN apk add --no-cache icu-dev \
    && docker-php-ext-configure intl \
    && docker-php-ext-install intl bcmath

WORKDIR /app

# Copy composer files
COPY composer.json composer.lock ./

# Install PHP dependencies (production only)
RUN composer install \
    --no-dev \
    --no-scripts \
    --no-interaction \
    --prefer-dist \
    --optimize-autoloader

# Copy application code
COPY . .

# Run composer scripts
RUN composer dump-autoload --optimize

# Publish Livewire assets (needed for livewire.min.js)
RUN php artisan livewire:publish --assets

# ============================================
# Stage 2: Frontend Build
# ============================================
FROM node:22-alpine AS frontend

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --prefer-offline --no-audit

# Copy source files needed for build INCLUDING vendor from composer stage
COPY resources ./resources
COPY public ./public
COPY vite.config.js ./

# Copy vendor directory from composer stage (needed for flux CSS imports)
COPY --from=composer /app/vendor ./vendor

# Build frontend assets
RUN npm run build

# ============================================
# Stage 3: Runtime Image
# ============================================
FROM php:8.4-fpm-alpine

# Set working directory
WORKDIR /var/www/html

# Install system dependencies and PHP extensions
RUN apk add --no-cache \
    nginx \
    supervisor \
    bash \
    curl \
    curl-dev \
    git \
    mariadb-client \
    postgresql-dev \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    oniguruma-dev \
    libxml2-dev \
    icu-dev \
    libmemcached-dev \
    zlib-dev \
    autoconf \
    g++ \
    make

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        pdo_pgsql \
        zip \
        gd \
        bcmath \
        soap \
        intl \
        mbstring \
        xml \
        curl \
        opcache

# Install PECL extensions
RUN pecl install redis igbinary msgpack \
    && docker-php-ext-enable redis igbinary msgpack

# Install ImageMagick
RUN apk add --no-cache imagemagick imagemagick-dev \
    && pecl install imagick \
    && docker-php-ext-enable imagick

# Configure PHP for production
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Copy custom PHP configuration
COPY --chown=www-data:www-data docker/php/php.ini "$PHP_INI_DIR/conf.d/99-laravel.ini"
COPY --chown=www-data:www-data docker/php/opcache.ini "$PHP_INI_DIR/conf.d/opcache.ini"

# Copy Nginx configuration
COPY --chown=www-data:www-data docker/nginx/default.conf /etc/nginx/http.d/default.conf

# Copy Supervisor configuration
COPY --chown=www-data:www-data docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy application code from composer stage
COPY --from=composer --chown=www-data:www-data /app /var/www/html

# Copy frontend assets from frontend stage
COPY --from=frontend --chown=www-data:www-data /app/public/build /var/www/html/public/build

# Copy Livewire published assets from composer stage
COPY --from=composer --chown=www-data:www-data /app/public/vendor/livewire /var/www/html/public/vendor/livewire

# Set proper permissions
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html/storage \
    && chmod -R 755 /var/www/html/bootstrap/cache

# Create necessary directories
RUN mkdir -p /var/www/html/storage/logs \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/framework/cache \
    /var/www/html/storage/app/backups \
    /run/nginx \
    /var/log/supervisor

# Create directory for persistent volumes (CapRover)
RUN mkdir -p /config /sql-import

# Copy entrypoint script
COPY --chown=www-data:www-data docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost/api/health || exit 1

# Expose port 80
EXPOSE 80

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
