"""STDIO transport implementation for MCP.

This module implements the Standard Input/Output transport as specified in the
Model Context Protocol (MCP). The transport handles:
- UTF-8 encoded JSON-RPC messages over stdin/stdout
- Newline-delimited message framing
- Proper error handling and logging to stderr
- Compliance with MCP 2025-03-26 specification
"""

from python import Python
from .parser import JSONRPCParser, JSONRPCSerializer
from .jsonrpc import JSONRPCError, parse_error, invalid_request, internal_error, JSONRPCRequest, JSONRPCResponse, JSONRPCNotification
from .server import MCPServer
from .transport import MCPTransport


@value
struct STDIOTransport(MCPTransport):
    """STDIO transport for MCP compliant with official specification.

    Per MCP specification:
    - Server reads JSON-RPC messages from stdin
    - Server writes JSON-RPC responses to stdout
    - Messages MUST be UTF-8 encoded
    - Messages MUST NOT contain embedded newlines
    - Server MAY write to stderr for logging
    - Server MUST NOT write non-MCP messages to stdout
    """

    var mcp_server: MCPServer
    var _is_running: Bool
    var debug_mode: Bool

    fn __init__(out self, mcp_server: MCPServer, debug_mode: Bool = False):
        self.mcp_server = mcp_server
        self._is_running = False
        self.debug_mode = debug_mode

    fn start(mut self) raises:
        """Start the STDIO transport and run the message loop."""
        if self._is_running:
            raise Error("STDIO transport is already running")

        self._is_running = True
        self._log_to_stderr_always("MCP STDIO transport starting...")

        # Start the underlying MCP server
        self.mcp_server.start()
        self._log_to_stderr_always("MCP server started")

        try:
            self._run_message_loop()
        finally:
            self._is_running = False
            self.mcp_server.stop()
            self._log_to_stderr_always("MCP STDIO transport stopped")

    fn stop(mut self):
        """Stop the STDIO transport loop."""
        self._is_running = False
        self._log_to_stderr("Stopping MCP STDIO Transport...")

    fn is_running(self) -> Bool:
        """Check if the transport is currently running."""
        return self._is_running

    fn _run_message_loop(mut self) raises:
        """Main message processing loop compliant with MCP STDIO specification."""
        while self._is_running:
            try:
                # Read a line from stdin (blocking)
                var line = self._read_line_from_stdin()

                # Skip empty lines as per MCP spec
                if len(line) == 0:
                    continue

                self._log_debug("Received: " + line)

                # Process the JSON-RPC message
                var response = self._process_mcp_message(line)

                # Send response if any (notifications don't have responses)
                if len(response) > 0:
                    self._write_line_to_stdout(response)
                    self._log_debug("Sent: " + response)

            except e:
                var error_msg = String(e)
                # Handle EOF gracefully (client disconnected)
                if error_msg.find("EOF") != -1 or error_msg.find("Failed to read from stdin") != -1:
                    self._log_to_stderr_always("Client disconnected (EOF), shutting down")
                    self._is_running = False
                    break

                # Log other errors but don't spam endless error responses
                self._log_to_stderr_always("Transport error: " + error_msg)

                # Break the loop on continuous errors to prevent infinite loops
                self._is_running = False
                break

    fn _read_line_from_stdin(self) raises -> String:
        """Read a single line from stdin."""
        try:
            # Use Python's sys.stdin to read a line
            var python = Python.import_module("sys")
            var line = python.stdin.readline()

            # Check for EOF - empty string means EOF in Python
            if not line or String(line) == "":
                raise Error("EOF reached")

            # Convert to Mojo string and strip newlines properly
            var result_str = String(line)

            # Manual newline stripping (MCP requires clean JSON-RPC lines)
            if len(result_str) > 0 and result_str[-1] == '\n':
                result_str = result_str[:-1]
            if len(result_str) > 0 and result_str[-1] == '\r':
                result_str = result_str[:-1]

            # Check if we got an empty line after stripping
            if len(result_str) == 0:
                return ""  # Return empty string for blank lines

            return result_str
        except e:
            # More specific error handling
            var error_msg = String(e)
            if error_msg.find("EOF") != -1:
                raise Error("EOF reached")
            else:
                raise Error("Failed to read from stdin: " + error_msg)

    fn _write_line_to_stdout(self, message: String) raises:
        """Write a single line to stdout with newline."""
        try:
            # Use Python's sys.stdout to write the line
            var python = Python.import_module("sys")
            python.stdout.write(String(message) + "\n")
            python.stdout.flush()
        except:
            raise Error("Failed to write to stdout")

    fn _log_to_stderr(self, message: String):
        """Log a message to stderr as permitted by MCP specification."""
        try:
            var python = Python.import_module("sys")
            python.stderr.write("[MCP-STDIO] " + String(message) + "\n")
            python.stderr.flush()
        except:
            pass  # Ignore logging errors to prevent infinite loops

    fn _log_to_stderr_always(self, message: String):
        """Log important messages to stderr regardless of debug mode."""
        try:
            var python = Python.import_module("sys")
            python.stderr.write("[MCP-STDIO] " + String(message) + "\n")
            python.stderr.flush()
        except:
            pass  # Ignore logging errors to prevent infinite loops

    fn _log_debug(self, message: String):
        """Log a debug message if debug mode is enabled."""
        if self.debug_mode:
            self._log_to_stderr("DEBUG: " + message)

    fn _process_mcp_message(mut self, json_body: String) raises -> String:
        """Process an MCP JSON-RPC message and return the response."""
        var parser = JSONRPCParser()
        var serializer = JSONRPCSerializer()

        self._log_debug("Processing MCP message: " + json_body)

        try:
            var message = parser.parse_message(json_body)
            self._log_debug("Message parsed successfully")

            # Handle different message types
            if message.isa[JSONRPCRequest]():
                var request = message[JSONRPCRequest]
                self._log_debug("Processing request: " + request.method)

                try:
                    # Use regular MCP server handling (STDIO doesn't need special session management)
                    var response = self.mcp_server.handle_request(request)
                    var serialized_response = serializer.serialize_response(response)
                    self._log_debug("Generated response: " + serialized_response)
                    return serialized_response
                except req_error:
                    self._log_debug("Request handling error: " + String(req_error))
                    var error_response = self._create_error_response(request.id, internal_error())
                    return error_response

            elif message.isa[JSONRPCNotification]():
                var notification = message[JSONRPCNotification]
                self._log_debug("Processing notification: " + notification.method)

                try:
                    # Handle notifications (no response expected)
                    self.mcp_server.handle_notification(notification)
                    return ""  # Notifications don't expect responses
                except notif_error:
                    self._log_debug("Notification handling error: " + String(notif_error))
                    return ""  # Still don't respond to notifications even if they fail

            else:
                # Responses are not expected in server context
                self._log_debug("Unexpected message type - treating as invalid request")
                var error_response = self._create_error_response("", invalid_request())
                return error_response

        except e:
            # Return parse error for invalid JSON-RPC
            self._log_debug("JSON-RPC parse error: " + String(e))
            var error_response = self._create_error_response("", parse_error())
            return error_response

    fn _create_error_response(self, id: String, error: JSONRPCError) -> String:
        """Create a JSON-RPC error response."""
        var serializer = JSONRPCSerializer()
        return serializer.serialize_error_response(id, error)

# Utility functions for creating MCP-compliant STDIO transports
fn create_stdio_transport(mcp_server: MCPServer, debug_mode: Bool = False) -> STDIOTransport:
    """Create a MCP-compliant STDIO transport."""
    return STDIOTransport(mcp_server, debug_mode)

fn create_debug_stdio_transport(mcp_server: MCPServer) -> STDIOTransport:
    """Create a MCP STDIO transport with debug logging enabled."""
    return STDIOTransport(mcp_server, True)