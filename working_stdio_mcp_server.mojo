"""STDIO MCP server example.

This demonstrates a complete MCP server that communicates via standard input/output
as specified in the MCP protocol for command-line integration.
"""

from lightbug_http.mcp import MCPServer
from lightbug_http.mcp.tools import MCPTool, MCPToolResult, MCPToolParameter, MCPToolAnnotation, create_string_parameter
from lightbug_http.mcp.stdio_server import create_stdio_mcp_server_runner

fn example_echo_tool(arguments_json: String) raises -> MCPToolResult:
    """Example echo tool that returns the input message."""
    var result = MCPToolResult()
    result.add_text_content("Echo: " + arguments_json)
    return result

fn main() raises:
    """Run a STDIO MCP server."""

    # print("=== MCP STDIO Server Example ===")
    # print("Protocol: MCP v2025-06-18 over STDIO")
    # print()

    # Create MCP server instance
    var mcp_server = MCPServer(server_name="lightbug-mcp-stdio", server_version="1.0.0")

    # Create and register example tools
    # print("Registering tools...")

    # Echo tool
    var echo_tool = MCPTool("echo", "Echoes back the provided message", "demo")
    var message_param = create_string_parameter("message", "The message to echo", True)
    echo_tool.add_parameter(message_param)
    var echo_annotation = MCPToolAnnotation("safe", 0, False)
    echo_annotation.add_tag("demo")
    echo_annotation.add_tag("text")
    echo_tool.annotations = echo_annotation

    try:
        mcp_server.register_tool(echo_tool, example_echo_tool)
        # print("Registered echo tool")
    except e:
        # print("ERROR: Failed to register echo tool: " + String(e))
        pass

    # Create and run STDIO server (debug mode off for production)
    var stdio_runner = create_stdio_mcp_server_runner(mcp_server, False)

    try:
        stdio_runner.run_stdio_server()
    except e:
        pass
        # print("Server error: " + String(e))
    finally:
        # print("\nServer stopped")