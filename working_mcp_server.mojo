"""Working MCP server example with Session Management and Tools.

This demonstrates the complete MCP Phase 3 implementation including:
- Session management with Mcp-Session-Id headers
- Enhanced Tools functionality with JSON Schema validation
"""

from lightbug_http import Server
from lightbug_http.mcp import MCPServer, HTTPTransport, create_session_manager
from lightbug_http.mcp.tools import MCPTool, MCPToolResult, MCPToolParameter, MCPToolRequest, create_string_parameter,create_number_parameter, TOOL_TYPE_STRING
from lightbug_http.mcp.utils import sleep_seconds
from collections import Dict

fn example_echo_tool(request: MCPToolRequest) raises -> MCPToolResult:
    var result = MCPToolResult()

    var message = request.get_string("message", "No message provided")

    result.add_text_content("Echo: " + message)
    return result

fn example_math_tool(request: MCPToolRequest) raises -> MCPToolResult:
    var result = MCPToolResult()

    try:
        var a_int = request.get_int("a", 0)
        var b_int = request.get_int("b", 0)
        var sum = a_int + b_int

        result.add_text_content("計算結果: " + String(sum))
    except:
        result.add_text_content("エラー: 無効な数値が提供されました。'a'と'b'に有効な整数値を提供してください。")

    return result

fn example_slow_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Example tool that takes a long time to demonstrate timeout functionality."""
    var result = MCPToolResult()

    # Get the delay parameter
    var delay_seconds = request.get_int("delay", 5)

    result.add_text_content("Starting slow operation for " + String(delay_seconds) + " seconds...")

    # Simulate slow work using actual sleep
    try:
        sleep_seconds(delay_seconds)
    except:
        result.add_text_content("Sleep operation failed - continuing without delay")

    result.add_text_content("Slow operation completed after " + String(delay_seconds) + " seconds!")
    return result

fn main() raises:

    var mcp_server = MCPServer(server_name="lightbug-mcp", server_version="1.0.0")

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
        parameters=[create_number_parameter("a", "First number", True), create_number_parameter("b", "Second number", True)],
        executor=example_math_tool
    )

    mcp_server.tool(
        name="slow_operation",
        description="A tool that simulates a slow operation to test timeout functionality",
        parameters=create_number_parameter("delay", "Delay in seconds for the operation", True),
        executor=example_slow_tool
    )

    mcp_server.start()