"""STDIO MCP server implementation.

This module provides a complete MCP-compliant STDIO server implementation
following the Model Context Protocol specification (2025-03-26).
It enables MCP servers to communicate over standard input/output streams
with proper initialization, lifecycle management, and error handling.
"""

from .server import MCPServer
from .stdio_transport import STDIOTransport, create_stdio_transport, create_debug_stdio_transport

@value
struct STDIOServer:
    """Complete MCP STDIO server implementation.

    This server provides:
    - Full MCP protocol compliance
    - STDIO transport lifecycle management
    - Proper initialization and shutdown sequences
    - Tool registration and execution
    - Error handling per MCP specification
    """

    var mcp_server: MCPServer
    var stdio_transport: STDIOTransport
    var is_running: Bool

    fn __init__(out self,
                server_name: String = "lightbug-mcp-stdio",
                server_version: String = "1.0.0",
                debug_mode: Bool = False):
        self.mcp_server = MCPServer(server_name, server_version)
        self.stdio_transport = create_stdio_transport(self.mcp_server, debug_mode)
        self.is_running = False

    fn start(mut self) raises:
        """Start the STDIO MCP server (preparation only)."""
        if self.is_running:
            raise Error("STDIO server is already running")

        # Mark as running (actual start happens in transport)
        self.is_running = True

    fn stop(mut self) raises:
        """Stop the STDIO MCP server."""
        if not self.is_running:
            return

        # Stop the transport (which also stops the MCP server)
        self.stdio_transport.stop()
        self.is_running = False

    fn run(mut self) raises:
        """Run the STDIO MCP server until completion.

        This is the main entry point for MCP STDIO servers.
        It handles the complete lifecycle per MCP specification.
        """
        self.start()

        try:
            # Start the STDIO transport (blocks until client disconnects)
            self.stdio_transport.start()
        finally:
            self.stop()

    fn get_server(mut self) -> MCPServer:
        """Get the underlying MCP server for tool registration."""
        return self.mcp_server

    fn get_transport(mut self) -> STDIOTransport:
        """Get the STDIO transport for advanced configuration."""
        return self.stdio_transport

@value
struct STDIOServerRunner:
    """STDIO MCP server runner for convenient server management.

    This provides a high-level interface for running MCP servers
    over STDIO transport with minimal configuration.
    """

    var mcp_server: MCPServer
    var debug_mode: Bool

    fn __init__(out self, mcp_server: MCPServer, debug_mode: Bool = True):
        self.mcp_server = mcp_server
        self.debug_mode = debug_mode

    fn run_stdio_server(mut self) raises:
        """Run the STDIO MCP server until completion.

        This is a convenience method that follows the MCP specification
        for STDIO transport servers.
        """
        # Create and configure STDIO transport
        var stdio_transport = create_stdio_transport(self.mcp_server, self.debug_mode)

        try:
            # Start the STDIO transport (includes MCP server startup)
            stdio_transport.start()
        except e:
            # Ensure cleanup on any error
            stdio_transport.stop()
            raise e

# Factory functions for creating MCP-compliant STDIO servers
fn create_stdio_server(server_name: String = "lightbug-mcp-stdio",
                      server_version: String = "1.0.0",
                      debug_mode: Bool = False) -> STDIOServer:
    """Create a new MCP-compliant STDIO server."""
    return STDIOServer(server_name, server_version, debug_mode)

fn create_debug_stdio_server(server_name: String = "lightbug-mcp-stdio",
                            server_version: String = "1.0.0") -> STDIOServer:
    """Create a new MCP STDIO server with debug logging enabled."""
    return STDIOServer(server_name, server_version, True)

fn create_stdio_mcp_server_runner(mcp_server: MCPServer, debug_mode: Bool = True) -> STDIOServerRunner:
    """Create a STDIO server runner with an existing MCP server.

    This is the recommended way to run MCP servers over STDIO transport.
    """
    return STDIOServerRunner(mcp_server, debug_mode)