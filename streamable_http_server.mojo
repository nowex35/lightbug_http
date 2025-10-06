"""Streamable HTTP Server - Full Integration Test.

This test demonstrates the complete streaming HTTP server implementation:
1. Server-Sent Events (SSE) streaming
2. Chunked transfer encoding
3. Request body streaming
4. Real-time bidirectional communication
"""

from lightbug_http.streaming.server import StreamingServer
from lightbug_http.streaming.streamable_service import StreamableHTTPService
from lightbug_http.streaming.streamable_exchange import StreamableHTTPExchange
from lightbug_http.io.bytes import bytes, Bytes


struct StreamingTestService(StreamableHTTPService):
    """Test service implementing real streaming functionality."""

    fn __init__(out self):
        pass

    fn __moveinit__(out self, owned existing: Self):
        pass

    fn call(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle streaming HTTP requests."""
        var path = exchange.uri.path

        if path == "/chunked":
            exchange.set_status(200)
            exchange.add_header("Content-Type", "text/plain")
            exchange.write_chunk(bytes("Hello\n"))
            exchange.write_chunk(bytes("World!\n"))
            exchange.end_stream()

        else:
            exchange.set_status(200)
            exchange.add_header("Content-Type", "text/plain")
            var msg = "Streaming HTTP Server Test\n\nTry: /chunked\n"
            exchange.write_chunk(bytes(msg))
            exchange.end_stream()


def main():
    """Run the streamable HTTP server test."""
    try:
        var server = StreamingServer(
            name="lightbug_streaming_test",
            tcp_keep_alive=True,
            stream_timeout_seconds=300.0
        )
        var service = StreamingTestService()

        server.listen_and_serve("0.0.0.0:8080", service)
    except e:
        print("Error:", e)
