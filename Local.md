# Running URL Shortener Locally

## Prerequisites

Make sure you have these installed before starting:

| Tool | Version | Install |
|------|---------|---------|
| Java | 21+ | [sdkman.io](https://sdkman.io) or [adoptium.net](https://adoptium.net) |
| Docker | 24+ | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| Docker Compose | v2+ | Bundled with Docker Desktop |
| Git | any | [git-scm.com](https://git-scm.com) |

> Gradle does **not** need to be installed separately — the project includes the Gradle wrapper (`./gradlew`).

---

## Option 1 — Spring Boot + Docker Compose (recommended)

This is the fastest way to get started. Docker Compose spins up PostgreSQL and the app together.

### Step 1 — Clone the repo

```bash
git clone https://github.com/YOUR_ORG/url-shortener.git
cd url-shortener
```

### Step 2 — Create a `docker-compose.yml` in the project root

```yaml
version: "3.9"

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: urlshortener
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 5

  app:
    build: .
    ports:
      - "8080:8080"
    environment:
      SPRING_DATASOURCE_URL: jdbc:postgresql://db:5432/urlshortener
      SPRING_DATASOURCE_USERNAME: postgres
      SPRING_DATASOURCE_PASSWORD: postgres
    depends_on:
      db:
        condition: service_healthy

volumes:
  pgdata:
```

### Step 3 — Start everything

```bash
docker compose up --build
```

The first run will build the Docker image (takes ~2 minutes). Subsequent starts are fast.

### Step 4 — Verify it's running

```bash
curl http://localhost:8080/health
# {"status":"UP"}
```

---

## Option 2 — Run Spring Boot directly (faster dev loop)

Use this when you're actively developing — no Docker rebuild needed on code changes.

### Step 1 — Start only PostgreSQL

```bash
docker run --name url-shortener-db \
  -e POSTGRES_DB=urlshortener \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d postgres:16-alpine
```

### Step 2 — Run the app with Gradle

```bash
./gradlew bootRun
```

The app starts on `http://localhost:8080`. Flyway will automatically create the `url_mappings` table on first boot.

### Step 3 — (Optional) Hot reload with Spring DevTools

Add this to `build.gradle.kts`:

```kotlin
developmentOnly("org.springframework.boot:spring-boot-devtools")
```

Then restart the server — code changes will trigger automatic restarts.

---

## Testing the API

Once the app is running, use these `curl` commands to test each endpoint.

### Shorten a URL

```bash
curl -s -X POST http://localhost:8080/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://aws.amazon.com/eks/", "ttlDays": 30}' | jq
```

Expected response:
```json
{
  "shortCode": "aB3kR7x",
  "originalUrl": "https://aws.amazon.com/eks/",
  "expiresAt": "2026-05-29T..."
}
```

### Follow a redirect

```bash
curl -v http://localhost:8080/aB3kR7x
# HTTP/1.1 302  Location: https://aws.amazon.com/eks/
```

### Check click stats

```bash
curl -s http://localhost:8080/api/stats/aB3kR7x | jq
```

Expected response:
```json
{
  "id": 1,
  "shortCode": "aB3kR7x",
  "originalUrl": "https://aws.amazon.com/eks/",
  "clickCount": 1,
  "createdAt": "...",
  "expiresAt": "..."
}
```

### Health & metrics

```bash
# Liveness probe
curl http://localhost:8080/health

# Spring Actuator health (detailed)
curl http://localhost:8080/actuator/health | jq

# Prometheus metrics
curl http://localhost:8080/actuator/prometheus
```

---

## Running Tests

Run the full test suite (Testcontainers spins up a real Postgres automatically — no manual setup needed):

```bash
./gradlew test
```

View the HTML test report after the run:

```bash
open build/reports/tests/test/index.html      # macOS
xdg-open build/reports/tests/test/index.html  # Linux
```

Run a single test class:

```bash
./gradlew test --tests "com.urlshortener.UrlControllerTest"
```

---

## Useful Gradle Tasks

| Command | What it does |
|---------|-------------|
| `./gradlew bootRun` | Start the app locally |
| `./gradlew test` | Run all tests |
| `./gradlew build` | Compile + test + build JAR |
| `./gradlew bootJar` | Build the fat JAR only (skips tests) |
| `./gradlew dependencies` | Show dependency tree |
| `./gradlew clean` | Delete the `build/` directory |

---

## Stopping & Cleaning Up

```bash
# Stop Docker Compose services
docker compose down

# Stop and remove the database volume (wipes all data)
docker compose down -v

# Stop the standalone Postgres container (Option 2)
docker stop url-shortener-db && docker rm url-shortener-db
```

---

## Troubleshooting

**Port 5432 already in use**
```bash
# Find what's using it
lsof -i :5432
# Kill it or change the host port mapping to 5433:5432 in docker-compose.yml
```

**`./gradlew: Permission denied`**
```bash
chmod +x ./gradlew
```

**Flyway migration error on startup**
The schema may be out of sync. Connect to the DB and check:
```bash
docker exec -it url-shortener-db psql -U postgres -d urlshortener
\dt                          -- list tables
SELECT * FROM flyway_schema_history;
```

**App fails to connect to DB**
Make sure the DB container is healthy before the app starts:
```bash
docker compose ps    # check the db service shows "healthy"
docker compose logs db
```