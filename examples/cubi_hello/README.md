# cubi_hello

A minimal Bandit app to deploy onto a running cubi node
([docs/specs.md](../../docs/specs.md) §2.11). It serves one page:

```
Welcome to Cubi
Version: 0.1.0
```

The version is the application's, so bump it in `mix.exs` to see a deploy or a
rollback take effect.

## Run it locally

```sh
mix deps.get
mix run --no-halt
curl http://localhost:8080/
```

The port is set in `config/config.exs` (default 8080). It is build-time
configuration on purpose: a cubi release does not run `config/runtime.exs`.

## Build it for a cubi node

`cubi_tools` is a `runtime: false` dependency, so the cubi tasks are
available here. Build against the served directory of the image you will
deploy to:

```sh
MIX_ENV=prod mix cubi.release --base ../../_build/x86_64_e2e/ipxe
```

The archive lands in `_build/prod/cubi/cubi_hello-0.1.0.tar.gz`. Your host's
OTP major and Elixir version must be the image's (see `base.json`).
