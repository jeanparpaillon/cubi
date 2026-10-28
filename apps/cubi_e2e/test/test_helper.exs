# e2e tests boot QEMU and are opt-in: `mix test --only e2e:tier1`.
ExUnit.start(exclude: [:e2e])
