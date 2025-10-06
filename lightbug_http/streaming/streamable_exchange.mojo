"""Streamable HTTP Exchange - unified request/response handling.

This module provides a unified interface for handling streaming HTTP
requests and responses, solving the connection ownership problem by
keeping the connection in the server while providing read/write access.
"""

from memory import Span
from collections import Optional
from lightbug_http.io.bytes import Bytes, ByteReader, ByteWriter, bytes
from lightbug_http.header import Headers, HeaderKey
from lightbug_http.cookie import RequestCookieJar
from lightbug_http.uri import URI
from lightbug_http.connection import TCPConnection
from lightbug_http.io.sync import Duration
from lightbug_http.strings import strHttp11


struct StreamableHTTPExchange:
    """HTTP Request/Response exchange with streaming support.

    This struct provides a unified interface for reading request data
    and writing response data over the same TCP connection. The connection
    is borrowed (not owned), allowing the server to maintain ownership.
    """

    # Request fields (read-only after parsing)
    var method: String
    var uri: URI
    var protocol: String
    var headers: Headers
    var cookies: RequestCookieJar

    # Response fields
    var response_status_code: Int
    var response_headers: Headers
    var _response_headers_sent: Bool

    # Streaming state
    var _connection: TCPConnection
    var _use_chunked_encoding: Bool
    var _content_length: Int
    var _bytes_read: Int
    var _is_complete: Bool
    var buffer_size: Int

    fn __init__(
        out self,
        owned connection: TCPConnection,
        method: String,
        uri: URI,
        protocol: String,
        headers: Headers,
        cookies: RequestCookieJar,
        content_length: Int = -1,
        buffer_size: Int = 4096
    ):
        """Initialize an HTTP exchange.

        Args:
            connection: The TCP connection (will be owned by this exchange)
            method: HTTP method (GET, POST, etc.)
            uri: Request URI
            protocol: HTTP protocol version
            headers: Request headers
            cookies: Request cookies
            content_length: Content-Length if known, -1 otherwise
            buffer_size: Buffer size for streaming operations
        """
        self.method = method
        self.uri = uri
        self.protocol = protocol
        self.headers = headers
        self.cookies = cookies

        self.response_status_code = 200
        self.response_headers = Headers()
        self._response_headers_sent = False

        self._connection = connection^
        self._use_chunked_encoding = True  # Default to chunked for streaming
        self._content_length = content_length
        self._bytes_read = 0
        self._is_complete = False
        self.buffer_size = buffer_size

    fn __moveinit__(out self, owned existing: Self):
        self.method = existing.method^
        self.uri = existing.uri^
        self.protocol = existing.protocol^
        self.headers = existing.headers^
        self.cookies = existing.cookies^

        self.response_status_code = existing.response_status_code
        self.response_headers = existing.response_headers^
        self._response_headers_sent = existing._response_headers_sent

        self._connection = existing._connection^
        self._use_chunked_encoding = existing._use_chunked_encoding
        self._content_length = existing._content_length
        self._bytes_read = existing._bytes_read
        self._is_complete = existing._is_complete
        self.buffer_size = existing.buffer_size

    @staticmethod
    fn from_connection(
        owned connection: TCPConnection,
        addr: String,
        max_uri_length: Int,
        initial_buffer: Span[Byte]
    ) raises -> StreamableHTTPExchange:
        """Create an exchange from a TCP connection with parsed headers.

        Args:
            connection: The TCP connection
            addr: Server address
            max_uri_length: Maximum allowed URI length
            initial_buffer: Buffer containing at least the request headers

        Returns:
            A StreamableHTTPExchange ready for use

        Raises:
            Error: If headers cannot be parsed or URI is too long
        """
        var reader = ByteReader(initial_buffer)
        var headers = Headers()
        var method: String
        var protocol: String
        var uri_str: String

        try:
            var rest = headers.parse_raw(reader)
            method, uri_str, protocol = rest[0], rest[1], rest[2]
        except e:
            raise Error("Failed to parse request headers: " + String(e))

        if len(uri_str.as_bytes()) > max_uri_length:
            raise Error("Request URI too long")

        var cookies = RequestCookieJar()
        try:
            cookies.parse_cookies(headers)
        except e:
            raise Error("Failed to parse cookies: " + String(e))

        var uri = URI.parse(addr + uri_str)
        var content_length = headers.content_length()

        return StreamableHTTPExchange(
            connection^,
            method,
            uri,
            protocol,
            headers,
            cookies,
            content_length
        )

    fn connection_close(self) raises -> Bool:
        """Check if the connection should be closed after this request.

        Returns:
            True if Connection: close header is present
        """
        if HeaderKey.CONNECTION in self.headers:
            return self.headers[HeaderKey.CONNECTION].lower() == "close"
        return False

    # ==================== Request Body Reading ====================

    fn read_body_chunk(mut self) raises -> Bytes:
        """Read the next chunk of the request body.

        Returns:
            The next chunk of data, or empty Bytes if complete

        Raises:
            Error: If a read error occurs
        """
        if self._is_complete:
            return Bytes()

        if self._content_length >= 0:
            var remaining = self._content_length - self._bytes_read
            if remaining <= 0:
                self._is_complete = True
                return Bytes()

            var to_read = min(remaining, self.buffer_size)
            var buffer = Bytes(capacity=to_read)
            var bytes_read = self._connection.read(buffer)

            if bytes_read == 0:
                self._is_complete = True
                return Bytes()

            self._bytes_read += bytes_read
            if self._bytes_read >= self._content_length:
                self._is_complete = True

            return buffer^

        # Content-Length unknown
        var buffer = Bytes(capacity=self.buffer_size)
        var bytes_read: Int
        try:
            bytes_read = self._connection.read(buffer)
        except e:
            if String(e) == "EOF":
                self._is_complete = True
                return Bytes()
            raise e

        if bytes_read == 0:
            self._is_complete = True
            return Bytes()

        self._bytes_read += bytes_read
        return buffer^

    # ==================== Response Writing ====================

    fn set_status(mut self, status_code: Int):
        """Set the response status code.

        Args:
            status_code: HTTP status code (e.g., 200, 404)
        """
        if not self._response_headers_sent:
            self.response_status_code = status_code

    fn add_header(mut self, key: String, value: String):
        """Add a response header.

        Args:
            key: Header name
            value: Header value
        """
        if not self._response_headers_sent:
            self.response_headers[key] = value

    fn start_sse_stream(mut self) raises:
        """Start a Server-Sent Events stream.

        Sets appropriate headers and sends them.

        Raises:
            Error: If headers were already sent
        """
        if self._response_headers_sent:
            raise Error("Headers already sent")

        self.response_headers["Content-Type"] = "text/event-stream"
        self.response_headers["Cache-Control"] = "no-cache"
        self.response_headers["Connection"] = "keep-alive"
        self._use_chunked_encoding = False  # SSE doesn't use chunked encoding

        self.send_headers()

    fn send_headers(mut self) raises:
        """Send the response headers.

        Raises:
            Error: If headers were already sent or write fails
        """
        if self._response_headers_sent:
            return

        # Build status line
        var status_line = self.protocol + " " + String(self.response_status_code) + " OK\r\n"

        # Add Transfer-Encoding if using chunked
        if self._use_chunked_encoding:
            self.response_headers["Transfer-Encoding"] = "chunked"

        # Build headers
        var writer = ByteWriter()
        writer.write(status_line)

        for entry in self.response_headers._inner.items():
            writer.write(entry.key, ": ", entry.value, "\r\n")

        writer.write("\r\n")

        # Send
        var header_bytes = writer^.consume()
        _ = self._connection.write(Span(header_bytes))

        self._response_headers_sent = True

    fn write_chunk(mut self, data: Bytes) raises:
        """Write a chunk of response data.

        Args:
            data: The data to write

        Raises:
            Error: If write fails
        """
        if not self._response_headers_sent:
            self.send_headers()

        if not self._use_chunked_encoding:
            # Direct write for SSE
            _ = self._connection.write(Span(data))
            return

        # Chunked encoding: size\r\ndata\r\n
        var writer = ByteWriter()
        writer.write(hex(len(data)), "\r\n")
        writer.write_bytes(Span(data))
        writer.write("\r\n")

        var chunk = writer^.consume()
        _ = self._connection.write(Span(chunk))

    fn write_sse_event(mut self, event_type: String, data: String, id: String = "") raises:
        """Write a Server-Sent Event.

        Args:
            event_type: Event type
            data: Event data
            id: Optional event ID

        Raises:
            Error: If write fails
        """
        var event_str = String()

        if event_type:
            event_str += "event: " + event_type + "\n"

        if id:
            event_str += "id: " + id + "\n"

        # Handle multi-line data
        var lines = data.split("\n")
        for i in range(len(lines)):
            event_str += "data: " + lines[i] + "\n"

        event_str += "\n"

        _ = self._connection.write(Span(bytes(event_str)))

    fn end_stream(mut self) raises:
        """End the response stream.

        For chunked encoding, sends the final 0-size chunk.

        Raises:
            Error: If write fails
        """
        if not self._response_headers_sent:
            self.send_headers()

        if self._use_chunked_encoding:
            var end_chunk = bytes("0\r\n\r\n")
            _ = self._connection.write(Span(end_chunk))

    fn flush(mut self) raises:
        """Flush any buffered data.

        Note: Current implementation writes directly, so this is a no-op.
        Included for API compatibility.
        """
        pass

    fn take_connection(owned self) -> TCPConnection:
        """Take ownership of the connection.

        This allows the server to reclaim the connection after the exchange is done.
        This method consumes the exchange.

        Returns:
            The TCP connection.
        """
        return self._connection^

    fn teardown(mut self) raises:
        """Close the connection."""
        self._connection.teardown()
