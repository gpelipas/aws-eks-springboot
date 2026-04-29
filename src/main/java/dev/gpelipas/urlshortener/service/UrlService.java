package dev.gpelipas.urlshortener.service;

import jakarta.transaction.Transactional;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import dev.gpelipas.urlshortener.model.UrlMapping;
import dev.gpelipas.urlshortener.repository.UrlRepository;

import java.time.LocalDateTime;
import java.util.Optional;
import java.util.Random;

@Service
public class UrlService {

    private static final String ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    private static final int CODE_LENGTH = 7;
    private final Random random = new Random();

    private final UrlRepository urlRepository;

    public UrlService(UrlRepository urlRepository) {
        this.urlRepository = urlRepository;
    }

    @Transactional
    public UrlMapping shorten(String originalUrl, Integer ttlDays) {
        String shortCode = generateUniqueCode();

        UrlMapping mapping = new UrlMapping(shortCode, originalUrl);
        if (ttlDays != null && ttlDays > 0) {
            mapping.setExpiresAt(LocalDateTime.now().plusDays(ttlDays));
        }

        return urlRepository.save(mapping);
    }

    @Transactional
    public Optional<String> resolve(String shortCode) {
        Optional<UrlMapping> mapping = urlRepository.findByShortCode(shortCode);

        if (mapping.isEmpty()) return Optional.empty();

        UrlMapping url = mapping.get();

        // Check expiry
        if (url.getExpiresAt() != null && url.getExpiresAt().isBefore(LocalDateTime.now())) {
            return Optional.empty();
        }

        urlRepository.incrementClickCount(shortCode);
        return Optional.of(url.getOriginalUrl());
    }

    public Optional<UrlMapping> getStats(String shortCode) {
        return urlRepository.findByShortCode(shortCode);
    }

    // Runs at midnight every day — removes expired rows
    @Scheduled(cron = "0 0 0 * * *")
    @Transactional
    public void purgeExpiredUrls() {
        int deleted = urlRepository.deleteExpiredMappings(LocalDateTime.now());
        System.out.printf("Purged %d expired URL mappings%n", deleted);
    }

    private String generateUniqueCode() {
        String code;
        do {
            code = randomCode();
        } while (urlRepository.existsByShortCode(code));
        return code;
    }

    private String randomCode() {
        StringBuilder sb = new StringBuilder(CODE_LENGTH);
        for (int i = 0; i < CODE_LENGTH; i++) {
            sb.append(ALPHABET.charAt(random.nextInt(ALPHABET.length())));
        }
        return sb.toString();
    }
}
