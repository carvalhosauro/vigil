import Config

config :logger, level: :warning
config :vigil, Vigil.Adapters.Provider, timeout: 100
