defmodule Probnik.Assets do
  use Scenic.Assets.Static,
    otp_app: :probnik,
    sources: [
      {:scenic, "deps/scenic/assets"},
      {:probnik, "assets"}
    ],
    alias: [
      courier: "fonts/courier.ttf",
      # Use regular Courier for bold to avoid driver crashes with the bold font file.
      courier_bold: "fonts/courier.ttf"
    ]
end
