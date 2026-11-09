# Vendored from Hermes Agent

`rfb_filter.py` is copied unchanged from
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
`tools/bot_desktop/rfb_filter.py` at commit `8c1a9c0b6da872cca5083b98a7a1022edc3dfb4b`
(2026-11-09), under the MIT license in `LICENSE` (Copyright (c) 2025 Nous Research).

It is the byte-level gate Hermes' display bridge runs on every client→server byte. The testbed
bridge (`../bridge.py`) and `Tests/RFBTests/BridgeFilterTests.swift` use it so that what our client
sends is judged by the same code as on the real server. When Hermes changes it, copy the new
version here and update the commit above.
