# CraftOS Blink Guide Control

This client-only Fabric mod is a narrow automation bridge used to reproduce the
in-game setup guide. It binds only to `127.0.0.1:8765` and exposes:

- `GET /health`
- `GET /state`
- `POST /command` with a Minecraft command as the request body
- `POST /use?x=N&y=N&z=N` to use a block with the main hand
- `POST /input?clear=true&submit=true` to type into the open GUI, optionally
  clearing and submitting it (intended for a CC:Tweaked computer screen)
- `POST /screenshot` to invoke Minecraft's own screenshot recorder

Every request is logged with its elapsed time. `/health` reports the age of
the latest render-thread heartbeat, and a timed-out client operation prints
the render-thread stack before returning an error. Screenshots copy pixels on
the render thread and write PNG files on the control worker.

It is not required to use CraftOS Blink. Do not add it to a public modpack or
bind it to a non-loopback interface: the command endpoint intentionally has the
creative/operator authority of the local player.

Build with Java 21:

```sh
./gradlew build
```

The guide automation pins Minecraft 1.21.1, Fabric Loader 0.19.3, and Fabric
API 0.116.15+1.21.1 in `gradle.properties`.
