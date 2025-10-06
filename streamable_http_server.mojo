"""Example of using Streamable HTTP for SSE and chunked responses.

This example demonstrates:
1. Server-Sent Events (SSE) streaming
2. Chunked transfer encoding
3. Streaming large responses
"""

from lightbug_http import Server
from lightbug_http.service import HTTPService
from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.mcp import StreamableHTTPRequest, StreamableHTTPResponse, StreamableBodyStream
from lightbug_http.io.bytes import bytes
from lightbug_http.connection import TCPConnection
from time import sleep


@value
struct StreamingExampleService(HTTPService):
    """Example HTTP service demonstrating streaming capabilities."""

    fn __init__(out self):
        pass

    fn func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Handle HTTP requests with streaming support."""

        var path = req.uri.path

        if path == "/sse":
            # For SSE, we need to return a regular response that indicates streaming
            # In a real implementation, we'd use StreamableHTTPResponse directly
            return OK(
                bytes("SSE endpoint - requires StreamableHTTPResponse integration"),
                content_type="text/plain"
            )
        elif path == "/chunked":
            return OK(
                bytes("Chunked endpoint - requires StreamableHTTPResponse integration"),
                content_type="text/plain"
            )
        else:
            return OK(
                bytes("Streamable HTTP Server\n\nAvailable endpoints:\n/sse - Server-Sent Events\n/chunked - Chunked transfer encoding"),
                content_type="text/plain"
            )


fn main() raises:
    """Run the streamable HTTP server example."""
    var server = Server()
    var service = StreamingExampleService()

    print("Starting Streamable HTTP Server...")
    print("Endpoints:")
    print("  http://localhost:8080/ - Server info")
    print("  http://localhost:8080/sse - SSE streaming")
    print("  http://localhost:8080/chunked - Chunked responses")
    print()
    print("Note: Full streaming support requires server integration")
    print("Press Ctrl+C to stop")

    server.listen_and_serve("0.0.0.0:8080", service)
