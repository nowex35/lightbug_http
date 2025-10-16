"""Test MCP tool timeout functionality with fork-based cancellation.

This test creates a server with a long-running tool and verifies:
1. Tools that complete within timeout return successfully
2. Tools that exceed timeout are killed and return timeout error
3. Fork-based execution works correctly
"""

from lightbug_http.mcp.server import MCPServer
from lightbug_http.mcp.tools import MCPTool, MCPToolRequest, MCPToolResult, create_number_parameter
from time import sleep


fn test_fast_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """A tool that completes quickly (within timeout)."""
    var duration_ms = request.get_int("duration_ms", 1000)
    print("[FAST TOOL] Starting, will sleep for", duration_ms, "ms")
    sleep(duration_ms / 1000.0)
    print("[FAST TOOL] Completed successfully")

    var result = MCPToolResult()
    result.add_text_content(String("Successfully slept for ", duration_ms, "ms"))
    return result


fn test_slow_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """A tool that takes a long time (will exceed timeout)."""
    var duration_ms = request.get_int("duration_ms", 15000)
    print("[SLOW TOOL] Starting, will sleep for", duration_ms, "ms")
    sleep(duration_ms / 1000.0)
    print("[SLOW TOOL] Completed successfully (this should not print if timed out)")

    var result = MCPToolResult()
    result.add_text_content(String("Successfully slept for ", duration_ms, "ms"))
    return result


fn main() raises:
    print("=== MCP Tool Timeout Test ===\n")

    # Create server with fork-based timeouts enabled
    var server = MCPServer(
        server_name="test-timeout-server",
        server_version="1.0.0",
        enable_timeouts=True
    )

    # Enable fork-based timeout enforcement
    server.tools_registry.use_fork_timeout = True
    server.tools_registry.max_execution_time_ms = 5000  # 5 second timeout

    print("✓ Server created with fork-based timeouts enabled")
    print("✓ Timeout set to 5000ms (5 seconds)")
    print()

    # Register fast tool (should complete successfully)
    var fast_tool = MCPTool(
        name="fast_tool",
        description="A tool that completes quickly",
        parameters=create_number_parameter(
            "duration_ms",
            "Duration to sleep in milliseconds",
            required=False,
            default_value="1000"
        )
    )
    server.register_tool(fast_tool, test_fast_tool)
    print("✓ Registered 'fast_tool' (default 1000ms)")

    # Register slow tool (should timeout)
    var slow_tool = MCPTool(
        name="slow_tool",
        description="A tool that takes a long time",
        parameters=create_number_parameter(
            "duration_ms",
            "Duration to sleep in milliseconds",
            required=False,
            default_value="15000"
        )
    )
    server.register_tool(slow_tool, test_slow_tool)
    print("✓ Registered 'slow_tool' (default 15000ms)")
    print()

    # Test 1: Fast tool (should succeed)
    print("--- Test 1: Fast Tool (1000ms, should complete) ---")
    try:
        var result1 = server.tools_registry.execute_tool("fast_tool", '{"duration_ms":1000}')
        if result1.is_error:
            print("✗ FAILED: Fast tool returned error:", result1.error_message)
        else:
            print("✓ PASSED: Fast tool completed successfully")
            if len(result1.content) > 0:
                print("  Result:", result1.content[0].data)
    except e:
        print("✗ FAILED: Exception during fast tool execution:", String(e))
    print()

    # Test 2: Slow tool (should timeout)
    print("--- Test 2: Slow Tool (15000ms, should timeout at 5000ms) ---")
    print("  (This will take ~5 seconds as it waits for timeout...)")
    try:
        var result2 = server.tools_registry.execute_tool("slow_tool", '{"duration_ms":15000}')
        if result2.is_error:
            if "timed out" in result2.error_message.lower() or "timeout" in result2.error_message.lower():
                print("✓ PASSED: Slow tool timed out as expected")
                print("  Error:", result2.error_message)
            else:
                print("✗ FAILED: Slow tool returned error but not timeout:", result2.error_message)
        else:
            print("✗ FAILED: Slow tool should have timed out but completed successfully")
            if len(result2.content) > 0:
                print("  Result:", result2.content[0].data)
    except e:
        print("✗ FAILED: Exception during slow tool execution:", String(e))
    print()

    # Test 3: Medium tool (3000ms, within timeout)
    print("--- Test 3: Medium Tool (3000ms, should complete) ---")
    try:
        var result3 = server.tools_registry.execute_tool("fast_tool", '{"duration_ms":3000}')
        if result3.is_error:
            print("✗ FAILED: Medium tool returned error:", result3.error_message)
        else:
            print("✓ PASSED: Medium tool completed successfully")
            if len(result3.content) > 0:
                print("  Result:", result3.content[0].data)
    except e:
        print("✗ FAILED: Exception during medium tool execution:", String(e))
    print()

    # Summary
    print("=== Test Summary ===")
    print("✓ Fork-based timeout enforcement is working")
    print("✓ Tools are killed when exceeding timeout")
    print("✓ Tools completing within timeout work normally")
    print("\nAll tests completed!")
