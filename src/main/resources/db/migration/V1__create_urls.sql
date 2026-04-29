-- V1__create_urls.sql
CREATE TABLE url_mappings (
    id          BIGSERIAL PRIMARY KEY,
    short_code  VARCHAR(10)   NOT NULL UNIQUE,
    original_url VARCHAR(2048) NOT NULL,
    click_count  BIGINT        NOT NULL DEFAULT 0,
    created_at   TIMESTAMP     NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMP
);

CREATE INDEX idx_short_code ON url_mappings (short_code);
CREATE INDEX idx_expires_at ON url_mappings (expires_at) WHERE expires_at IS NOT NULL;
