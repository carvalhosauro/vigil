import Config

config :vigil, Vigil.Adapters.Provider, timeout: 10_000

import_config "#{config_env()}.exs"
