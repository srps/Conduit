# VPN and Chrome recovery validation

Use this plan after choosing to install Conduit 0.5.4. Preparing the release
does not install it, restart the serving app, or change the helper. This is an
app-only update from 0.5.3; helper v5 remains compatible.

Record the installed Conduit version, Chrome version, approximate VPN-cycle
times, and whether you disconnected intentionally or the VPN dropped. Keep
Chrome open throughout each cycle so the result tests recovery of the existing
browser session.

| Exercise | What to check |
| --- | --- |
| Fresh requests | Open pages before the VPN cycle, then open fresh tabs and reload an existing page after reconnect. They should work without restarting Chrome or Conduit. |
| Existing stream | Start a long download or streaming page before disconnecting. A healthy TCP connection may continue across the transition. A failed tunnel should close so Chrome can retry; a page may need a reload. Record a connection that stays open but makes no progress after reconnect. |
| Slow response tail | Use a large download or a throttled test page. Let it finish normally and compare the file size/checksum when available. A normal server close must not truncate the queued response, even if Chrome sends late bytes. |
| Tab cancellation | Close a downloading/streaming tab during a slow transfer, then open more tabs. Canceled streams should release their upstream sockets; subsequent requests should remain usable. |
| Repeated cycles | Repeat a brief disconnect/reconnect several times, including a cycle during a stream and one after a tab closes. Check fresh requests and existing pages each time. |

Conduit preserves healthy streams during VPN state changes. It does not replay
opaque TCP/TLS bytes or promise to resume a socket whose address or connection
has failed. The useful distinction is between a stream that resumes, one that
ends and can be retried, and one that silently remains stalled.

For a failure, record whether a fresh tab works, whether reload works, and
whether recovery needed a browser/app restart. Capture the matching Conduit
events or log interval around the VPN cycle. `tunnel.relay_failed` includes
socket side, operation, errno, relay age/idle time, observed byte counts, and
the routing cause at attachment/failure. Byte counts describe reads, not
acknowledged delivery. Do not include credentials, cookies, or authorization
headers in a report.

The deterministic fault scenario and unit tests cover known socket errors,
blocked writes, cancellation, and orderly EOF. This usage pass is needed to
check Chrome's own retries and real VPN timing. Silent network loss still
depends on the existing TCP keepalive and I/O error detection.
