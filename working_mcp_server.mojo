"""Working MCP server example with Session Management and Tools.

This demonstrates the complete MCP Phase 3 implementation including:
- Session management with Mcp-Session-Id headers
- Enhanced Tools functionality with JSON Schema validation
"""

from lightbug_http import Server
from lightbug_http.mcp import MCPServer, HTTPTransport, create_session_manager
from lightbug_http.mcp.tools import MCPTool, MCPToolResult, MCPToolParameter,create_string_parameter, TOOL_TYPE_STRING
from collections import Dict

fn example_echo_tool(arguments_json: String) raises -> MCPToolResult:
    """Example echo tool that returns the input message."""
    var result = MCPToolResult()

    # Parse the message from the JSON arguments
    var message = String("No message provided")

    # Extract 'message' parameter
    var message_start = arguments_json.find('"message"')
    if message_start != -1:
        var message_colon = arguments_json.find(':', message_start)
        if message_colon != -1:
            var message_quote_start = arguments_json.find('"', message_colon)
            if message_quote_start != -1:
                var message_quote_end = arguments_json.find('"', message_quote_start + 1)
                if message_quote_end != -1:
                    message = arguments_json[message_quote_start + 1:message_quote_end]

    result.add_text_content("Echo: " + message)
    return result

fn example_math_tool(arguments_json: String) raises -> MCPToolResult:
    """Example math tool for addition."""
    var result = MCPToolResult()
    
    # Parse JSON arguments to extract 'a' and 'b' values
    var a_value = String("0")
    var b_value = String("0")
    
    # Extract 'a' parameter
    var a_start = arguments_json.find('"a"')
    if a_start != -1:
        var a_colon = arguments_json.find(':', a_start)
        if a_colon != -1:
            var a_quote_start = arguments_json.find('"', a_colon)
            if a_quote_start != -1:
                var a_quote_end = arguments_json.find('"', a_quote_start + 1)
                if a_quote_end != -1:
                    a_value = arguments_json[a_quote_start + 1:a_quote_end]
    
    # Extract 'b' parameter
    var b_start = arguments_json.find('"b"')
    if b_start != -1:
        var b_colon = arguments_json.find(':', b_start)
        if b_colon != -1:
            var b_quote_start = arguments_json.find('"', b_colon)
            if b_quote_start != -1:
                var b_quote_end = arguments_json.find('"', b_quote_start + 1)
                if b_quote_end != -1:
                    b_value = arguments_json[b_quote_start + 1:b_quote_end]
    
    # Convert strings to integers and perform addition
    try:
        var a_int = atol(a_value)
        var b_int = atol(b_value)
        var sum = a_int + b_int
        
        var response = String("Math result: ") + a_value + " + " + b_value + " = " + String(sum)
        result.add_text_content(response)
    except:
        result.add_text_content("Error: Invalid numbers provided. Please provide valid integer values for 'a' and 'b'.")
    
    return result

fn main() raises:
    
    var mcp_server = MCPServer(server_name="lightbug-mcp", server_version="1.0.0")

    mcp_server.tool(
        name="echo",
        description="Echoes back the provided message",
        parameters=create_string_parameter("message", "The message to echo", True),
        executor=example_echo_tool
    )
    
    mcp_server.tool(
        name="math_add",
        description="Performs addition of two numbers",
        parameters=[create_string_parameter("a", "First number", True), create_string_parameter("b", "Second number", True)],
        executor=example_math_tool
    )

    mcp_server.start()