defmodule Probnik.Assets do
  use Scenic.Assets.Static,
    otp_app: :probnik,
    sources: [
      {:scenic, "deps/scenic/assets"},
      {:probnik, "assets"}
    ],
    alias: [
      courier: "fonts/courier.ttf",
      courier_bold: "fonts/courier_bold.ttf"
    ]
end
