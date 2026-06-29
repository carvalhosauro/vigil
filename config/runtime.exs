import Config

# Runtime configuration — evaluated when the release boots, not at build time.
# Secrets (e.g. Telegram token) are read from the environment here. See RFC-0003.
#
# Example (wired up in a later RFC implementation):
#
#   if config_env() == :prod do
#     config :vigil, :telegram, token: System.fetch_env!("TELEGRAM_TOKEN")
#   end
