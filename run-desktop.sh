#!/usr/bin/env bash
set -euo pipefail

epmd -daemon
exec iex --sname probnik --cookie secret_token -S mix scenic.run
