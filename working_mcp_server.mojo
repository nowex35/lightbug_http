"""Working MCP server example with Session Management and Tools.

This demonstrates the complete MCP Phase 3 implementation including:
- Session management with Mcp-Session-Id headers
- Enhanced Tools functionality with JSON Schema validation
- Tool annotations and safety features
"""

from lightbug_http import Server
from lightbug_http.mcp import MCPServer, HTTPTransport, create_session_manager
from lightbug_http.mcp.tools import MCPTool, MCPToolResult, MCPToolParameter, MCPToolAnnotation, create_string_parameter, TOOL_TYPE_STRING

fn example_echo_tool(arguments_json: String) raises -> MCPToolResult:
    """Example echo tool that returns the input message."""
    var result = MCPToolResult()
    result.add_text_content("Echo: " + arguments_json)
    return result

fn example_math_tool(arguments_json: String) raises -> MCPToolResult:
    """Example math tool for addition."""
    var result = MCPToolResult()
    result.add_text_content("Math result: 2 + 3 = 5")
    return result

fn main() raises:
    """Run a working MCP server with session management and tools."""
    
    print("=== MCP Server with Session Management & Enhanced Tools ===")
    print("Phase 3 Implementation Test")
    print()
    
    # Create MCP server instance
    var mcp_server = MCPServer(server_name="lightbug-mcp-phase3", server_version="1.0.0")
    
    # Create and register example tools with full JSON Schema support
    print("Registering tools...")
    
    # Echo tool with parameter validation
    var echo_tool = MCPTool("echo", "Echoes back the provided message", "demo")
    var message_param = create_string_parameter("message", "The message to echo", True)
    echo_tool.add_parameter(message_param)
    var echo_annotation = MCPToolAnnotation("safe", 0, False)
    echo_annotation.add_tag("demo")
    echo_annotation.add_tag("text")
    echo_tool.annotations = echo_annotation
    mcp_server.register_tool(echo_tool, example_echo_tool)
    
    # Math tool with parameter validation
    var math_tool = MCPTool("math_add", "Performs addition of two numbers", "math")
    var num1_param = create_string_parameter("a", "First number", True)
    var num2_param = create_string_parameter("b", "Second number", True)
    math_tool.add_parameter(num1_param)
    math_tool.add_parameter(num2_param)
    var math_annotation = MCPToolAnnotation("safe", 10, False)  # 10 requests per minute
    math_annotation.add_tag("math")
    math_annotation.add_tag("calculation")
    math_tool.annotations = math_annotation
    mcp_server.register_tool(math_tool, example_math_tool)
    
    # Start the MCP server
    mcp_server.start()
    
    print("MCP server initialized successfully")
    print("Server: " + mcp_server.get_server_info().name + " v" + mcp_server.get_server_info().version)
    print("Capabilities: tools=" + String(mcp_server.get_server_capabilities().tools))
    print("Tools registered: 2 (echo, math_add)")
    print("Active sessions: " + String(mcp_server.get_active_session_count()))
    print()
    
    # Create HTTP transport with the MCP server as handler
    var http_transport = HTTPTransport(mcp_server)
    
    # Create underlying HTTP server
    var http_server = Server(
        name="lightbug-mcp-http-phase3",
        address="127.0.0.1",
        max_concurrent_connections=100
    )
    
    print("Starting HTTP server on localhost:8081...")
    print("MCP endpoint: http://localhost:8081/")
    print()
    print("Session Management Features:")
    print("- Automatic session creation on initialize")
    print("- 30-minute session timeout")  
    print("- Mcp-Session-Id header support")
    print("- Automatic expired session cleanup")
    print()
    print("Enhanced Tools Features:")
    print("- JSON Schema validation")
    print("- Tool annotations (danger level, rate limits)")
    print("- Parameter type validation")
    print("- Concurrent execution limits")
    print()
    print("Example requests:")
    print("1. Initialize: POST with {'jsonrpc':'2.0','method':'initialize','params':{'protocolVersion':'2025-06-18','clientInfo':{'name':'test','version':'1.0'}},'id':'1'}")
    print("2. Tools list: POST with {'jsonrpc':'2.0','method':'tools/list','params':{},'id':'2'}")
    print("3. Echo tool: POST with {'jsonrpc':'2.0','method':'tools/call','params':{'name':'echo','arguments':{'message':'Hello'}},'id':'3'}")
    print()
    print("Press Ctrl+C to stop")
    
    try:
        # Start listening for HTTP requests
        http_server.listen_and_serve[HTTPTransport]("localhost:8081", http_transport)
    except e:
        print("Server error: " + String(e))
    finally:
        # Cleanup
        print("\nShutting down...")
        print("Final session count: " + String(mcp_server.get_active_session_count()))
        var cleaned = mcp_server.cleanup_expired_sessions()
        print("Cleaned up " + String(cleaned) + " expired sessions")
        mcp_server.stop()
        print("MCP server stopped")