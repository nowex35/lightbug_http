"""Working MCP server example that actually handles HTTP requests.

This is a minimal example that demonstrates real HTTP communication with MCP.
"""

from lightbug_http import Server
from lightbug_http.mcp import MCPServer, HTTPTransport

fn main() raises:
    """Run a working MCP server that handles HTTP requests."""
    
    print("Creating MCP server...")
    
    # Create MCP server instance
    var mcp_server = MCPServer(server_name="lightbug-mcp-example", server_version="1.0.0")
    
    # Start the MCP server
    mcp_server.start()
    
    print("MCP server initialized successfully")
    print("Server: " + mcp_server.get_server_info().name + " v" + mcp_server.get_server_info().version)
    print("Capabilities: tools=" + String(mcp_server.get_server_capabilities().tools))
    
    # Create HTTP transport with the MCP server as handler
    var http_transport = HTTPTransport(mcp_server)
    
    # Create underlying HTTP server
    var http_server = Server(
        name="lightbug-mcp-http",
        address="127.0.0.1",
        max_concurrent_connections=100
    )
    
    print("Starting HTTP server on localhost:8080...")
    print("MCP endpoint: http://localhost:8080/")
    print("Press Ctrl+C to stop")
    
    try:
        # Start listening for HTTP requests
        http_server.listen_and_serve[HTTPTransport]("localhost:8081", http_transport)
    except e:
        print("Server error: " + String(e))
    finally:
        mcp_server.stop()
        print("MCP server stopped")