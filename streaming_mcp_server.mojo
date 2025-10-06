"""Streaming MCP Server Example.

This demonstrates MCP running on StreamableHTTP with streaming support for:
- Real-time tool execution updates
- Large response streaming via chunked encoding
- Server-Sent Events for notifications
"""

from lightbug_http.streaming.server import StreamingServer
from lightbug_http.mcp import MCPServer, StreamingTransport
from lightbug_http.mcp.tools import MCPToolResult, MCPToolRequest, create_string_parameter, create_number_parameter
from lightbug_http.mcp.utils import sleep_seconds


fn example_echo_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Simple echo tool that returns the input message."""
    var result = MCPToolResult()
    var message = request.get_string("message", "No message provided")
    result.add_text_content("Echo: " + message)
    return result


fn example_math_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Math tool that performs addition."""
    var result = MCPToolResult()

    try:
        var a_int = request.get_int("a", 0)
        var b_int = request.get_int("b", 0)
        var sum = a_int + b_int
        result.add_text_content("Result: " + String(sum))
    except:
        result.add_text_content("Error: Invalid numbers provided.")

    return result


fn streaming_counter_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Tool that counts to demonstrate streaming capability."""
    var result = MCPToolResult()
    var count = request.get_int("count", 10)

    var output = String("Counting to ") + String(count) + ":\n"
    for i in range(1, count + 1):
        output += String(i)
        if i < count:
            output += ", "

    result.add_text_content(output)
    return result


fn slow_processing_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Tool that simulates slow processing."""
    var result = MCPToolResult()
    var delay = request.get_int("delay", 3)

    result.add_text_content("Starting slow operation for " + String(delay) + " seconds...")

    try:
        sleep_seconds(delay)
    except:
        result.add_text_content("Sleep failed - continuing without delay")

    result.add_text_content("Processing completed!")
    return result


fn main() raises:
    """Run the streaming MCP server."""

    # Create MCP server
    var mcp_server = MCPServer(
        server_name="lightbug-streaming-mcp",
        server_version="1.0.0"
    )

    # Mark server as running (since we're using StreamingTransport, not calling start())
    mcp_server.is_running = True

    # Register tools
    mcp_server.tool(
        name="echo",
        description="Echoes back the provided message",
        parameters=create_string_parameter("message", "The message to echo", True),
        executor=example_echo_tool
    )

    mcp_server.tool(
        name="math_add",
        description="Performs addition of two numbers",
        parameters=[
            create_number_parameter("a", "First number", True),
            create_number_parameter("b", "Second number", True)
        ],
        executor=example_math_tool
    )

    mcp_server.tool(
        name="counter",
        description="Counts to a specified number",
        parameters=create_number_parameter("count", "Number to count to", True),
        executor=streaming_counter_tool
    )

    mcp_server.tool(
        name="slow_process",
        description="Simulates slow processing with configurable delay",
        parameters=create_number_parameter("delay", "Delay in seconds", True),
        executor=slow_processing_tool
    )

    # Create streaming transport
    var transport = StreamingTransport(mcp_server)

    # Create streaming server
    var server = StreamingServer(
        name="lightbug_streaming_mcp",
        tcp_keep_alive=True,
        stream_timeout_seconds=300.0
    )

    # Print startup info
    print("=" * 60)
    print("Streaming MCP Server")
    print("=" * 60)
    print()
    print("MCP endpoint: http://127.0.0.1:8083/mcp")
    print("Health check: http://127.0.0.1:8083/health")
    print("SSE endpoint: http://127.0.0.1:8083/sse")
    print()
    print("Example request:")
    print('  curl -X POST http://127.0.0.1:8083/mcp \\')
    print('    -H "Content-Type: application/json" \\')
    print('    -d \'{"jsonrpc":"2.0","method":"initialize",')
    print('         "params":{"protocolVersion":"2025-06-18",')
    print('                   "clientInfo":{"name":"test","version":"1.0"}},')
    print('         "id":"1"}\'')
    print()
    print("Press Ctrl+C to stop")
    print("=" * 60)
    print()

    # Start server
    server.listen_and_serve("127.0.0.1:8080", transport)
