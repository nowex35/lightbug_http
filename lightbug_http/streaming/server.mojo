"""Streaming HTTP Server implementation.

This module extends the base Server functionality to support streaming
HTTP requests and responses, enabling efficient handling of large payloads
and real-time communication patterns like Server-Sent Events.
"""

from memory import Span
from lightbug_http.io.sync import Duration
from lightbug_http.io.bytes import Bytes, BytesConstant, ByteView, bytes
from lightbug_http._logger import logger
from lightbug_http.connection import NoTLSListener, default_buffer_size, TCPConnection, ListenConfig
from lightbug_http.http import encode
from lightbug_http.http.common_response import InternalError, BadRequest, URITooLong
from lightbug_http.streaming.streamable_exchange import StreamableHTTPExchange
from lightbug_http.streaming.streamable_service import StreamableHTTPService
from lightbug_http.streaming.stream_manager import StreamManager
from lightbug_http.streaming.shared_connection import SharedConnection
from lightbug_http.error import ErrorHandler


alias default_max_request_body_size = 4 * 1024 * 1024  # 4MB
alias default_max_request_uri_length = 8192


struct StreamingServer(Movable):
    """A streaming-capable HTTP server for Mojo.

    This server supports both traditional HTTP request/response handling
    and streaming patterns including:
    - Chunked transfer encoding
    - Server-Sent Events (SSE)
    - Large file uploads/downloads
    - Real-time bidirectional communication
    """

    var error_handler: ErrorHandler
    var name: String
    var _address: String
    var max_concurrent_connections: UInt
    var max_requests_per_connection: UInt
    var _max_request_body_size: UInt
    var _max_request_uri_length: UInt
    var tcp_keep_alive: Bool
    var _stream_manager: StreamManager

    fn __init__(
        out self,
        name: String = "lightbug_http_streaming",
        address: String = "127.0.0.1",
        max_concurrent_connections: UInt = 1000,
        max_requests_per_connection: UInt = 0,
        max_request_body_size: UInt = default_max_request_body_size,
        max_request_uri_length: UInt = default_max_request_uri_length,
        tcp_keep_alive: Bool = True,  # Streaming benefits from keep-alive
        stream_timeout_seconds: Float64 = 300.0,
    ) raises:
        var error_handler = ErrorHandler()
        self.error_handler = error_handler
        self.name = name
        self._address = address
        self.max_requests_per_connection = max_requests_per_connection
        self._max_request_body_size = max_request_body_size
        self._max_request_uri_length = max_request_uri_length
        self.tcp_keep_alive = tcp_keep_alive
        self.max_concurrent_connections = max_concurrent_connections if max_concurrent_connections > 0 else 1000
        self._stream_manager = StreamManager(stream_timeout_seconds)

    fn __moveinit__(out self, owned other: StreamingServer):
        self.error_handler = other.error_handler^
        self.name = other.name^
        self._address = other._address^
        self.max_concurrent_connections = other.max_concurrent_connections
        self.max_requests_per_connection = other.max_requests_per_connection
        self._max_request_body_size = other._max_request_body_size
        self._max_request_uri_length = other._max_request_uri_length
        self.tcp_keep_alive = other.tcp_keep_alive
        self._stream_manager = other._stream_manager^

    fn address(self) -> ref [self._address] String:
        return self._address

    fn set_address(mut self, own_address: String):
        self._address = own_address

    fn listen_and_serve[T: StreamableHTTPService](
        mut self,
        address: String,
        mut handler: T
    ) raises:
        """Listen for incoming connections and serve streaming HTTP requests.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            address: The address (host:port) to listen on.
            handler: An object that handles incoming streaming HTTP requests.
        """
        var config = ListenConfig()
        var listener = config.listen(address)
        self.set_address(address)
        self.serve(listener^, handler)

    fn serve[T: StreamableHTTPService](
        mut self,
        owned ln: NoTLSListener,
        mut handler: T
    ) raises:
        """Serve streaming HTTP requests.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections.
            handler: An object that handles incoming streaming HTTP requests.
        """
        while True:
            var conn = ln.accept()
            var shared_conn = SharedConnection(conn^)
            
            try:
                self.serve_connection(shared_conn, handler)
            except e:
                logger.error("Error serving connection:", String(e))
                shared_conn.teardown()

            _ = self._stream_manager.cleanup_idle_streams()

    fn serve_connection[T: StreamableHTTPService](
        mut self,
        shared_conn: SharedConnection,
        mut handler: T
    ) raises -> None:
        """Serve a single streaming connection.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            shared_conn: A shared connection object representing a client connection.
            handler: An object that handles incoming streaming HTTP requests.
        """
        logger.debug(
            "Streaming connection accepted! Remote:",
            shared_conn.get_remote_address()
        )

        var max_request_uri_length = self._max_request_uri_length
        if max_request_uri_length <= 0:
            max_request_uri_length = default_max_request_uri_length

        var req_number = 0
        req_number += 1

        # Read headers
        var header_buffer = Bytes()
        while True:
            try:
                var temp_buffer = Bytes(capacity=default_buffer_size)
                var bytes_read = shared_conn.read(temp_buffer)
                logger.debug("Bytes read:", bytes_read)

                if bytes_read == 0:
                    shared_conn.teardown()
                    return

                header_buffer.extend(temp_buffer^)

                if BytesConstant.DOUBLE_CRLF in ByteView(header_buffer):
                    logger.debug("Found end of headers")
                    break

            except e:
                shared_conn.teardown()
                if String(e) == "EOF":
                    return
                else:
                    logger.error("Failed to read headers:", String(e))
                    return

        # Parse request
        var exchange: StreamableHTTPExchange
        try:
            exchange = StreamableHTTPExchange.from_connection(
                shared_conn,
                self.address(),
                Int(max_request_uri_length),
                Span(header_buffer)
            )
        except e:
            logger.error("Failed to parse request:", String(e))
            return

        # Register the stream
        var stream_id = self._stream_manager.generate_stream_id()
        var session_id = self._stream_manager.generate_session_id()
        self._stream_manager.register_stream(stream_id, session_id)

        var req_method = exchange.method
        var req_path = exchange.uri.path

        # Call the streaming service handler
        var handler_error: Optional[String] = None
        try:
            handler.call(exchange)
        except e:
            handler_error = String(e)

        logger.debug(req_method, req_path, exchange.response_status_code, "(streaming)")

        # Clean up the stream
        _ = self._stream_manager.cleanup_stream(stream_id)

        # Handle errors
        if handler_error:
            logger.error("Handler error:", handler_error.value())
            shared_conn.teardown()

    fn active_streams(self) -> Int:
        """Get the number of currently active streams.

        Returns:
            The count of active streaming connections.
        """
        return self._stream_manager.active_stream_count()
