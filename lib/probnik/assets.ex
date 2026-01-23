defmodule Probnik.Assets do
  use Scenic.Assets.Static,
    otp_app: :probnik,
    sources: [
      {:scenic, "deps/scenic/assets"}
    ]
end
