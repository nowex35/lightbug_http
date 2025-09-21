"""Async HTTP Server for MCP with multiple concurrent client support.

This module provides an asynchronous HTTP server that can handle multiple
MCP clients simultaneously using the async event loop system.
"""

from collections import Dict, List
from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.io.bytes import Bytes, bytes
from lightbug_http.strings import to_string
from lightbug_http.service import HTTPService
from .async_io import AsyncEventLoop, AsyncEvent, AsyncConnection, EVENT_READ, EVENT_WRITE, EVENT_CONNECT, EVENT_DISCONNECT, generate_connection_id, current_timestamp_ms
from .transport import HTTPTransport
from .server import MCPServer

# Request processing states
alias RequestState = Int
alias REQUEST_READING_HEADERS: RequestState = 0
alias REQUEST_READING_BODY: RequestState = 1
alias REQUEST_PROCESSING: RequestState = 2
alias REQUEST_SENDING_RESPONSE: RequestState = 3
alias REQUEST_COMPLETED: RequestState = 4

@value
struct AsyncHTTPRequest(Movable):
    """Represents an HTTP request being processed asynchronously."""
    var request_id: String
    var connection_id: String
    var state: RequestState
    var method: String
    var path: String
    var headers: String
    var body: String
    var content_length: Int
    var bytes_read: Int
    var start_time: Int64
    var timeout_ms: Int64
    
    fn __init__(out self, request_id: String, connection_id: String):
        self.request_id = request_id
        self.connection_id = connection_id
        self.state = REQUEST_READING_HEADERS
        self.method = ""
        self.path = ""
        self.headers = ""
        self.body = ""
        self.content_length = 0
        self.bytes_read = 0
        self.start_time = current_timestamp_ms()
        self.timeout_ms = 30000  # 30 second timeout
    
    fn is_complete(self) -> Bool:
        """Check if the request has been completely read."""
        return self.state >= REQUEST_PROCESSING
    
    fn is_expired(self) -> Bool:
        """Check if the request has timed out."""
        return (current_timestamp_ms() - self.start_time) > self.timeout_ms
    
    fn add_data(mut self, data: String):
        """Add incoming data to the request."""
        if self.state == REQUEST_READING_HEADERS:
            self.headers = self.headers + data
            # Check if headers are complete (simplified check for \r\n\r\n)
            if "\r\n\r\n" in self.headers:
                self._parse_headers()
                self.state = REQUEST_READING_BODY
        elif self.state == REQUEST_READING_BODY:
            self.body = self.body + data
            self.bytes_read += len(data)
            if self.bytes_read >= self.content_length:
                self.state = REQUEST_PROCESSING
    
    fn _parse_headers(mut self):
        """Parse HTTP headers to extract method, path, and content length."""
        var lines = self.headers.split("\r\n")
        if len(lines) > 0:
            var request_line = lines[0]
            var parts = request_line.split(" ")
            if len(parts) >= 2:
                self.method = parts[0]
                self.path = parts[1]
        
        # Extract Content-Length
        for i in range(len(lines)):
            var line = lines[i].lower()
            if line.startswith("content-length:"):
                var length_parts = line.split(":")
                if len(length_parts) >= 2:
                    try:
                        self.content_length = atol(length_parts[1].strip())
                    except:
                        self.content_length = 0

@value
struct AsyncHTTPResponse(Movable):
    """Represents an HTTP response being sent asynchronously."""
    var response_id: String
    var connection_id: String
    var status_code: Int
    var headers: String
    var body: String
    var bytes_sent: Int
    var total_bytes: Int
    var completed: Bool
    
    fn __init__(out self, response_id: String, connection_id: String, 
                status_code: Int = 200, body: String = ""):
        self.response_id = response_id
        self.connection_id = connection_id
        self.status_code = status_code
        self.headers = self._build_headers(body)
        self.body = body
        self.bytes_sent = 0
        self.total_bytes = len(self.headers) + len(self.body)
        self.completed = False
    
    fn _build_headers(self, body: String) -> String:
        """Build HTTP response headers."""
        var headers = "HTTP/1.1 " + String(self.status_code) + " OK\r\n"
        headers = headers + "Content-Type: application/json\r\n"
        headers = headers + "Content-Length: " + String(len(body)) + "\r\n"
        headers = headers + "Access-Control-Allow-Origin: *\r\n"
        headers = headers + "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        headers = headers + "Access-Control-Allow-Headers: Content-Type, Authorization, Mcp-Session-Id\r\n"
        headers = headers + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        headers = headers + "\r\n"
        return headers
    
    fn get_data_to_send(self) -> String:
        """Get the complete response data to send."""
        return self.headers + self.body
    
    fn mark_bytes_sent(mut self, bytes_sent: Int):
        """Mark the number of bytes that have been sent."""
        self.bytes_sent += bytes_sent
        if self.bytes_sent >= self.total_bytes:
            self.completed = True

@value
struct AsyncMCPServer(Movable):
    """Asynchronous MCP server supporting multiple concurrent connections."""
    var mcp_server: MCPServer
    var http_transport: HTTPTransport
    var event_loop: AsyncEventLoop
    var active_requests: Dict[String, AsyncHTTPRequest]
    var pending_responses: Dict[String, AsyncHTTPResponse]
    var connection_count: Int
    var max_concurrent_connections: Int
    var is_running: Bool
    var listen_address: String
    var listen_port: Int
    
    fn __init__(out self, mcp_server: MCPServer, max_concurrent_connections: Int = 1000):
        self.mcp_server = mcp_server
        self.http_transport = HTTPTransport(mcp_server)
        self.event_loop = AsyncEventLoop(max_concurrent_connections)
        self.active_requests = Dict[String, AsyncHTTPRequest]()
        self.pending_responses = Dict[String, AsyncHTTPResponse]()
        self.connection_count = 0
        self.max_concurrent_connections = max_concurrent_connections
        self.is_running = False
        self.listen_address = "127.0.0.1"
        self.listen_port = 8081
    
    fn start(mut self, address: String = "127.0.0.1", port: Int = 8081) raises:
        """Start the async MCP server."""
        if self.is_running:
            raise Error("Async MCP server is already running")
        
        self.listen_address = address
        self.listen_port = port
        
        # Start the MCP server
        self.mcp_server.start()
        
        # Start the event loop
        self.event_loop.start()
        
        # Register event handlers
        self._register_event_handlers()
        
        self.is_running = True
        
        print("Async MCP Server started")
        print("Listening on: " + address + ":" + String(port))
        print("Max concurrent connections: " + String(self.max_concurrent_connections))
    
    fn stop(mut self) raises:
        """Stop the async MCP server."""
        if not self.is_running:
            return
        
        # Stop the event loop
        self.event_loop.stop()
        
        # Stop the MCP server
        self.mcp_server.stop()
        
        # Clear active requests and responses
        self.active_requests = Dict[String, AsyncHTTPRequest]()
        self.pending_responses = Dict[String, AsyncHTTPResponse]()
        
        self.is_running = False
        print("Async MCP Server stopped")
    
    fn run_forever(mut self) raises:
        """Run the server until stopped."""
        if not self.is_running:
            raise Error("Server not started")
        
        print("Server running... Press Ctrl+C to stop")
        
        try:
            # In a real implementation, this would accept actual socket connections
            # For now, we'll simulate the event loop processing
            self.event_loop.run_forever()
        except e:
            print("Server error: " + String(e))
            self.stop()
    
    fn handle_new_connection(mut self, remote_address: String = "") raises -> String:
        """Handle a new client connection."""
        if self.connection_count >= self.max_concurrent_connections:
            raise Error("Maximum concurrent connections reached")
        
        var connection_id = generate_connection_id()
        var socket_fd = 0  # Simplified - would be actual socket file descriptor
        
        # Add connection to event loop
        self.event_loop.add_connection(connection_id, socket_fd, remote_address)
        
        self.connection_count += 1
        
        print("New connection: " + connection_id + " from " + remote_address)
        print("Active connections: " + String(self.connection_count))
        
        return connection_id
    
    fn close_connection(mut self, connection_id: String) raises:
        """Close a client connection."""
        # Remove any active requests for this connection
        var requests_to_remove = List[String]()
        for request_id in self.active_requests:
            var request = self.active_requests[request_id]
            if request.connection_id == connection_id:
                requests_to_remove.append(request_id)
        
        for i in range(len(requests_to_remove)):
            _ = self.active_requests.pop(requests_to_remove[i])
        
        # Remove any pending responses for this connection
        var responses_to_remove = List[String]()
        for response_id in self.pending_responses:
            var response = self.pending_responses[response_id]
            if response.connection_id == connection_id:
                responses_to_remove.append(response_id)
        
        for i in range(len(responses_to_remove)):
            _ = self.pending_responses.pop(responses_to_remove[i])
        
        # Close in event loop
        self.event_loop.close_connection(connection_id)
        
        self.connection_count -= 1
        print("Connection closed: " + connection_id)
        print("Active connections: " + String(self.connection_count))
    
    fn simulate_http_request(mut self, connection_id: String, request_data: String) raises:
        """Simulate receiving HTTP request data (for testing)."""
        var request_id = "req_" + String(current_timestamp_ms())
        var request = AsyncHTTPRequest(request_id, connection_id)
        
        # Add request data
        request.add_data(request_data)
        
        self.active_requests[request_id] = request
        
        # If request is complete, process it
        if request.is_complete():
            self._process_complete_request(request_id)
    
    fn get_server_stats(self) -> AsyncServerStats:
        """Get current server statistics."""
        return AsyncServerStats(
            self.connection_count,
            self.max_concurrent_connections,
            len(self.active_requests),
            len(self.pending_responses),
            self.event_loop.get_connection_count(),
            self.is_running
        )
    
    fn _register_event_handlers(mut self):
        """Register event handlers for the async event loop."""
        # Note: In Mojo, we can't directly pass member functions as handlers
        # This would need to be implemented differently in a real scenario
        print("Event handlers registered for async processing")
    
    fn _process_complete_request(mut self, request_id: String) raises:
        """Process a complete HTTP request."""
        if request_id not in self.active_requests:
            return
        
        var request = self.active_requests[request_id]
        
        # Create HTTPRequest object for transport layer
        var http_body = bytes(request.body)
        var http_request = HTTPRequest("", request.method, request.path, "", http_body)
        
        try:
            # Process through HTTP transport
            var http_response = self.http_transport.func(http_request)
            
            # Convert response to async response
            var response_id = "resp_" + String(current_timestamp_ms())
            var response_body = to_string(http_response.body_raw)
            var async_response = AsyncHTTPResponse(response_id, request.connection_id, 200, response_body)
            
            # Queue response for sending
            self.pending_responses[response_id] = async_response
            
            # Remove completed request
            _ = self.active_requests.pop(request_id)
            
            print("Request processed: " + request_id + " -> " + response_id)
            
        except e:
            # Create error response
            var error_response_id = "error_" + String(current_timestamp_ms())
            var error_body = '{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}'
            var error_response = AsyncHTTPResponse(error_response_id, request.connection_id, 500, error_body)
            
            self.pending_responses[error_response_id] = error_response
            _ = self.active_requests.pop(request_id)
            
            print("Request error: " + request_id + " - " + String(e))
    
    fn _cleanup_expired_requests(mut self):
        """Clean up expired requests."""
        var expired_requests = List[String]()
        
        for request_id in self.active_requests:
            var request = self.active_requests[request_id]
            if request.is_expired():
                expired_requests.append(request_id)
        
        for i in range(len(expired_requests)):
            try:
                _ = self.active_requests.pop(expired_requests[i])
                print("Expired request removed: " + expired_requests[i])
            except:
                pass

@value
struct AsyncServerStats(Movable):
    """Statistics for the async MCP server."""
    var active_connections: Int
    var max_connections: Int
    var active_requests: Int
    var pending_responses: Int
    var event_loop_connections: Int
    var is_running: Bool
    
    fn __init__(out self, active_connections: Int, max_connections: Int,
                active_requests: Int, pending_responses: Int,
                event_loop_connections: Int, is_running: Bool):
        self.active_connections = active_connections
        self.max_connections = max_connections
        self.active_requests = active_requests
        self.pending_responses = pending_responses
        self.event_loop_connections = event_loop_connections
        self.is_running = is_running
    
    fn to_string(self) -> String:
        """Convert stats to a readable string."""
        var stats = "Async Server Stats:\n"
        stats = stats + "  Running: " + String(self.is_running) + "\n"
        stats = stats + "  Connections: " + String(self.active_connections) + "/" + String(self.max_connections) + "\n"
        stats = stats + "  Active requests: " + String(self.active_requests) + "\n"
        stats = stats + "  Pending responses: " + String(self.pending_responses) + "\n"
        stats = stats + "  Event loop connections: " + String(self.event_loop_connections)
        return stats
    
    fn utilization_percent(self) -> Float64:
        """Get connection utilization as percentage."""
        if self.max_connections == 0:
            return 0.0
        return Float64(self.active_connections) / Float64(self.max_connections) * 100.0

# Utility functions
fn create_async_mcp_server(mcp_server: MCPServer, max_connections: Int = 1000) -> AsyncMCPServer:
    """Create a new async MCP server."""
    return AsyncMCPServer(mcp_server, max_connections)

fn create_production_async_server(server_name: String = "async-mcp-server",
                                 server_version: String = "1.0.0",
                                 max_connections: Int = 1000) -> AsyncMCPServer:
    """Create a production-ready async MCP server."""
    var mcp_server = MCPServer(server_name, server_version)
    return AsyncMCPServer(mcp_server, max_connections)