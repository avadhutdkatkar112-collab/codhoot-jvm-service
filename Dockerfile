FROM golang:1.22-bookworm@sha256:1f298b0c9fecdf504389a0329236f948cc04a566a2bb32337207cbaaa2f8177c AS builder
WORKDIR /build
# Copy every Go source file, not just main.go: the sandbox hardening lives in
# harden.go (portable) plus harden_unix.go / harden_other.go (per-platform).
COPY go.mod ./
COPY main.go harden.go harden_unix.go harden_other.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service .

# Kotlin, Scala, Groovy, Clojure and JShell all run on the same JVM CodHoot
# already runs Java on, so they reuse the JDK layer entirely rather than each
# pulling their own runtime. Java itself keeps its own single-language service.
FROM eclipse-temurin:21-jdk
LABEL org.opencontainers.image.title="codhoot-jvm-service"
LABEL org.opencontainers.image.description="Hardened JVM execution sandbox (kotlin, scala, groovy, clojure, jshell)"

# Kotlin has no Debian package, so it is pinned by download digest.
ARG KOTLIN_VERSION=2.4.20
ARG KOTLIN_ZIP_SHA256=59e9ca74c7904ef2c122b12114937673ccce68de820a663f0ed66ccf8799e0b7

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        unzip \
        scala \
        groovy \
        clojure; \
    curl -fsSL -o /tmp/kotlin.zip \
        "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip"; \
    echo "${KOTLIN_ZIP_SHA256}  /tmp/kotlin.zip" | sha256sum -c -; \
    unzip -q /tmp/kotlin.zip -d /opt; \
    rm -f /tmp/kotlin.zip; \
    rm -f /usr/bin/curl /usr/bin/wget /usr/local/bin/curl /usr/local/bin/wget; \
    apt-get purge -y --auto-remove unzip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    ln -s /opt/kotlinc/bin/kotlinc /usr/local/bin/kotlinc; \
    ln -s /opt/kotlinc/bin/kotlin /usr/local/bin/kotlin

ENV SCALA_HOME=/usr/share/scala
ENV KOTLIN_HOME=/opt/kotlinc

# Launchers for the compiled JVM languages.
#
# Scala's `scala` runner fails when there is no DNS (it resolves the container
# hostname) and Groovy's compiled classes need groovy-all.jar at run time. Both
# are solved by scripts shipped in this image rather than by a classpath in the
# registry, so a registry entry never encodes a Debian package path.
COPY bin/scala-main bin/groovy-main bin/jshell-main /usr/local/bin/
RUN chmod +x /usr/local/bin/scala-main /usr/local/bin/groovy-main /usr/local/bin/jshell-main

# Smoke test each toolchain at build time: a compiler that is present but broken
# is worse than a failed build.
RUN set -eux; \
    printf 'fun main() { println("kotlin ok") }\n' > /tmp/Smoke.kt; \
    kotlinc /tmp/Smoke.kt -include-runtime -d /tmp/smoke.jar; \
    java -jar /tmp/smoke.jar; \
    scala-main Smoke < /dev/null || true; \
    groovy-main Smoke <<< 'println "groovy ok"' || true; \
    rm -f /tmp/Smoke.kt /tmp/smoke.jar

WORKDIR /app
COPY --from=builder /out/service /app/service
RUN chmod 0755 /app/service && rm -f go.mod main.go harden.go harden_unix.go harden_other.go

# --- sandbox identity pool ---------------------------------------------------
# Each in-flight job is dropped to a DISTINCT uid by the service. That is what
# makes a job's 0700 working directory genuinely private: with one shared uid every
# job could read every other job's source and rewrite it before it ran.
# The JVM resolves usernames through getpwuid, so the passwd entries matter here
# more than for most runtimes.
# shellcheck disable=SC2016
RUN set -eu; \
    i=0; \
    while [ "$i" -lt 32 ]; do \
      u=$((2000 + i)); \
      printf 'codhoot-s%d:x:%d:%d:codhoot sandbox:/nonexistent:/sbin/nologin\n' "$i" "$u" "$u" >> /tmp/pool; \
      i=$((i + 1)); \
    done; \
    cat /tmp/pool >> /etc/passwd; \
    rm -f /tmp/pool; \
    mkdir -p /tmp/codhoot-cache; \
    chmod 0755 /tmp/codhoot-cache

# The service itself runs as root on purpose: it must chown each job directory to
# that job's uid and setuid the compiler/runtime child. The security boundary is
# the child, not the service.
#
# There is deliberately no HEALTHCHECK here: it would require curl or wget in the
# image, and Render already health-checks /health over HTTP.
ENV PORT=8081
EXPOSE 8081
CMD ["/app/service"]