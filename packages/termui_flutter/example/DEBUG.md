# Debugging through docker

When running agents in docker and you want to get the tooling to hotreload:

1. Host side:

```shell
flutter run -d windows --debug `
   --device-vmservice-port=50301 `
   --host-vmservice-port=50302 `
   --dds-port=50303 `
   --disable-service-auth-codes `
   --print-dtd
```

convert the DTD printout to `host.docker.internal` instead of 127.0.0.1

2. Start docker

```shell
docker run -it --rm  --add-host=host.docker.internal:host-gateway  -v ".:/app"  -v 'dart_tool_cache:/app/.dart_tool'  -v "dart_build_cache:/app/build" -v "$HOME\.gemini:/home/codefu/.gemini" flutter-workspace:latest
```
