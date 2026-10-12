# codhoot-jvm-service

Execution server for CodHoot's **JVM** languages — Kotlin, Scala, Groovy,
Clojure and JShell. They all compile to and run on the same JVM CodHoot already
runs Java on, so they share one JDK layer instead of each pulling their own
runtime.

Java keeps its own service (`codhoot-java-service`), which the backend reaches
through `COMPILER_JAVA_SERVICE_URL`; this service is never asked for it.

## Why this service exists

CodHoot's single-language services each hard-code one compiler and one entry
filename, so they cannot be reused for a language they were not built for —
pointing Kotlin at the Java service would run `javac` over a `.kt` file. The
backend routes the rest of the JVM family here through the shared runtime image
URL:

```
COMPILER_IMAGE_JVM_SERVICE_URL=https://codhoot-jvm-service-<suffix>.onrender.com
```

One variable covers all five languages. The mapping is read at backend startup,
so set the variable and restart the backend service.

## Contract

`POST /compile`, signed with
`HMAC-SHA256(secret, timestamp + path + hex(sha256(body)))` keyed by
`CODHOOT_INTERNAL_SECRET`, headers `X-CodHoot-Timestamp` (unix seconds) and
`X-CodHoot-Signature` (hex digest). Unsigned, tampered or stale requests get
401.

```json
{ "language": "kotlin", "source": "fun main() { println(\"hi\") }" }
```

`GET /health` and `GET /health/live` are open — Render's health check and the
keepalive pinger must never need a signature.

| language | entry file     | compile                                          | run                      |
|----------|----------------|--------------------------------------------------|--------------------------|
| clojure  | `main.clj`     | —                                                | `clojure {src}`          |
| groovy   | `Main.groovy`  | `groovyc {src}`                                  | `groovy-main Main`       |
| jshell   | `main.jsh`     | —                                                | `jshell-main {src}`      |
| kotlin   | `Main.kt`      | `kotlinc {src} -include-runtime -d main.jar`     | `java -jar main.jar`     |
| scala    | `Main.scala`   | `scalac -d . {src}`                             | `scala-main Main`        |

Those command lines are the backend registry's own `CompileCommand` and
`RunCommand` for each language, so a job behaves identically to the local
`codhoot-runner-jvm` docker path.

### The three launchers

`bin/scala-main`, `bin/groovy-main` and `bin/jshell-main` are the same launcher
scripts `codhoot-runner-jvm` ships, copied here unchanged. They exist because
the stock commands fail inside the sandbox or need a classpath the registry
should not have to know:

- Scala's `scala` runner resolves the container hostname, and there is no DNS.
- Groovy's compiled classes need `groovy-all.jar` on the classpath at run time.
- JShell needs flags that keep it from waiting on a terminal.

## Toolchains

Temurin 21 (the JDK CodHoot already uses), Debian bookworm's Scala, Groovy and
Clojure, and Kotlin 2.4.20 from the JetBrains release zip, sha256-pinned —
Kotlin has no Debian package.

## Deployment

Render blueprint: **New → Blueprint**, point it at this repo, apply. Set
`CODHOOT_INTERNAL_SECRET` to the same value the backend uses.

The service listens on `PORT` (Render sets it to 10000; the image default is
8081). `MAX_CONCURRENT_JOBS` defaults to 2: each JVM job costs hundreds of
megabytes, which is the binding constraint on a 512 MB instance.

## Sandbox

Each job gets its own uid from a 32-entry pool, a private random 0700 working
directory, a minimal environment, rlimits applied by a trampoline re-exec, and
process-group kill on timeout. The passwd entries matter more here than for most
runtimes: the JVM derives `user.name` from `getpwuid`. The service runs as root
only to chown and setuid; the boundary is the child. See `harden.go` /
`harden_unix.go`.