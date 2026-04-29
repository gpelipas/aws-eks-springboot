package dev.gpelipas.urlshortener.controller;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import dev.gpelipas.urlshortener.model.UrlMapping;
import dev.gpelipas.urlshortener.service.UrlService;

import java.net.URI;
import java.util.Map;
import java.util.Optional;

@RestController
public class UrlController {

    private final UrlService urlService;

    public UrlController(UrlService urlService) {
        this.urlService = urlService;
    }

    // POST /api/shorten
    @PostMapping("/api/shorten")
    public ResponseEntity<ShortenResponse> shorten(@Valid @RequestBody ShortenRequest request) {
        UrlMapping mapping = urlService.shorten(request.url(), request.ttlDays());
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(new ShortenResponse(mapping.getShortCode(), mapping.getOriginalUrl(), mapping.getExpiresAt()));
    }

    // GET /{code}  — redirect
    @GetMapping("/{code}")
    public ResponseEntity<Void> redirect(@PathVariable @Pattern(regexp = "[a-zA-Z0-9]{5,10}") String code) {
        Optional<String> target = urlService.resolve(code);
        if (target.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.status(HttpStatus.FOUND)
                .header(HttpHeaders.LOCATION, target.get())
                .build();
    }

    // GET /api/stats/{code}
    @GetMapping("/api/stats/{code}")
    public ResponseEntity<UrlMapping> stats(@PathVariable String code) {
        return urlService.getStats(code)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    // Health probe (used by K8s liveness/readiness)
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP"));
    }

    // --- DTOs ---

    public record ShortenRequest(
            @NotBlank String url,
            Integer ttlDays
    ) {}

    public record ShortenResponse(
            String shortCode,
            String originalUrl,
            Object expiresAt
    ) {}
}
