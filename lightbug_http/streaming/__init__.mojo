"""Streaming HTTP implementation for lightbug_http.

This module provides streaming-capable HTTP components:
- StreamableHTTPExchange: Unified request/response handling
- StreamableHTTPService: Service trait for streaming handlers
- StreamingServer: Server with streaming support
- StreamManager: Session and stream management

Example:
    ```mojo
    from lightbug_http.streaming import StreamingServer, StreamableHTTPService, StreamableHTTPExchange

    @value
    struct MyService(StreamableHTTPService):
        fn call(mut self, mut exchange: StreamableHTTPExchange) raises:
            exchange.add_header("Content-Type", "text/plain")
            exchange.send_headers()
            exchange.write_chunk(bytes("Hello, streaming world!"))
            exchange.end_stream()

    fn main() raises:
        var server = StreamingServer()
        var service = MyService()
        server.listen_and_serve("0.0.0.0:8080", service)
    ```
"""

from .streamable_exchange import StreamableHTTPExchange
from .streamable_service import StreamableHTTPService
from .server import StreamingServer
from .stream_manager import StreamManager, StreamInfo
from .streamable_body_stream import StreamableBodyStream

# Legacy exports (for backward compatibility with mcp/)
from .streamable_request import StreamableHTTPRequest
from .streamable_response import StreamableHTTPResponse
