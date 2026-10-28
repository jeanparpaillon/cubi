# kubex_hello

A minimal Bandit app to deploy onto a running kubex node
([docs/specs.md](../../docs/specs.md) §2.11). It serves one page:

```
Welcome to Kubex
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
configuration on purpose: a kubex release does not run `config/runtime.exs`.

## Build it for a kubex node

`kubex_tools` is a `runtime: false` dependency, so the kubex tasks are
available here. Build against the served directory of the image you will
deploy to:

```sh
MIX_ENV=prod mix kubex.release --base ../../_build/x86_64_e2e/ipxe
```

The archive lands in `_build/prod/kubex/kubex_hello-0.1.0.tar.gz`. Your host's
OTP major and Elixir version must be the image's (see `base.json`).
