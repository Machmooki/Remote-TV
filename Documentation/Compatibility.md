# PLAYBOX connection evidence

User supplied: AIS PLAYBOX / ZTE V8754920 / STBAZA-A / Panasonic HDMI display; IP `192.168.1.130`, Bluetooth MAC `B8:59:CE:5E:1D:06`.

Observed from the development Mac on 2026-10-11:

- TCP connections to selected IP ports 6466 and 6467 were accepted.
- Bonjour `_androidtvremote2._tcp.local.` advertised a service on 6466. Its TXT `bt` attribute matched the MAC provided by the user. This MAC is an identifier, not a pairing code.
- `Tools/ProbePLAYBOX.swift`, compiled from the production Swift TLS/protocol sources, completed TLS 6467 with an ephemeral RSA identity and received valid Polo v2 request, options and configuration acknowledgements, including six-character hexadecimal encoding support.
- The probe stopped before secret submission, closed the pairing channel, persisted no credentials and sent no remote commands. It may briefly show a pairing code on the TV.

This is actual network/protocol evidence for the selected endpoint, not a completed physical iPhone test. The user subsequently reported successful connection from the physical iPhone, followed by repeated disconnects. The receive-only timeout defect and recovery changes are documented in `ConnectionRecovery.md`. Extended stability after this fix, persistent reconnection and the physical effects of individual commands still require the user's iPhone/TV test. Bluetooth emulation and Panasonic HDMI-CEC behavior are not established by these observations.

See [physical test steps](Verification.md) and [implementation details](Protocol.md).
