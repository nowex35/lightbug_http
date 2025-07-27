"""MCP-specific message types and structures.

This module defines the MCP protocol messages that build on top of JSON-RPC 2.0,
including initialization, capabilities, tools, resources, and prompts.
"""

from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification

# MCP Protocol Version
alias MCP_PROTOCOL_VERSION = "2025-06-18"

@value
struct MCPClientInfo(Movable):
    """Information about the MCP client."""
    var name: String
    var version: String
    
    fn __init__(out self, name: String, version: String):
        self.name = name
        self.version = version
    
    fn to_json(self) -> String:
        return String('{"name":"', self.name, '","version":"', self.version, '"}')

@value 
struct MCPServerInfo(Movable):
    """Information about the MCP server."""
    var name: String
    var version: String
    
    fn __init__(out self, name: String, version: String):
        self.name = name
        self.version = version
    
    fn to_json(self) -> String:
        return String('{"name":"', self.name, '","version":"', self.version, '"}')

@value
struct MCPCapabilities(Movable):
    """MCP server or client capabilities."""
    var tools: Bool
    var resources: Bool
    var prompts: Bool
    var logging: Bool
    var roots: Bool
    var sampling: Bool
    
    fn __init__(out self, tools: Bool = False, resources: Bool = False, 
                prompts: Bool = False, logging: Bool = False,
                roots: Bool = False, sampling: Bool = False):
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
        self.roots = roots
        self.sampling = sampling
    
    fn to_json(self) -> String:
        var json = String("{")
        var first = True
        
        if self.tools:
            json = json + '"tools":{}'
            first = False
        if self.resources:
            if not first:
                json = json + ","
            json = json + '"resources":{}'
            first = False
        if self.prompts:
            if not first:
                json = json + ","
            json = json + '"prompts":{}'
            first = False
        if self.logging:
            if not first:
                json = json + ","
            json = json + '"logging":{}'
            first = False
        if self.roots:
            if not first:
                json = json + ","
            json = json + '"roots":{}'
            first = False
        if self.sampling:
            if not first:
                json = json + ","
            json = json + '"sampling":{}'
        
        json = json + "}"
        return json

# MCP-specific message creation functions

fn create_initialize_request(id: String, client_info: MCPClientInfo, 
                           capabilities: MCPCapabilities) -> JSONRPCRequest:
    """Create an MCP initialize request."""
    var params = String('{"protocolVersion":"', MCP_PROTOCOL_VERSION, 
                       '","capabilities":', capabilities.to_json(),
                       ',"clientInfo":', client_info.to_json(), '}')
    return JSONRPCRequest(id, "initialize", params)

fn create_initialize_response(id: String, server_info: MCPServerInfo,
                            capabilities: MCPCapabilities) -> JSONRPCResponse:
    """Create an MCP initialize response."""
    var result = String('{"protocolVersion":"', MCP_PROTOCOL_VERSION,
                       '","capabilities":', capabilities.to_json(),
                       ',"serverInfo":', server_info.to_json(), '}')
    return JSONRPCResponse.success(id, result)

fn create_initialized_notification() -> JSONRPCNotification:
    """Create an MCP initialized notification."""
    return JSONRPCNotification("initialized", "{}")

fn create_tools_list_request(id: String) -> JSONRPCRequest:
    """Create a tools/list request."""
    return JSONRPCRequest(id, "tools/list", "{}")

fn create_tools_call_request(id: String, tool_name: String, arguments: String) -> JSONRPCRequest:
    """Create a tools/call request."""
    var params = String('{"name":"', tool_name, '","arguments":', arguments, '}')
    return JSONRPCRequest(id, "tools/call", params)

fn create_resources_list_request(id: String) -> JSONRPCRequest:
    """Create a resources/list request."""
    return JSONRPCRequest(id, "resources/list", "{}")

fn create_resources_read_request(id: String, uri: String) -> JSONRPCRequest:
    """Create a resources/read request."""
    var params = String('{"uri":"', uri, '"}')
    return JSONRPCRequest(id, "resources/read", params)

fn create_prompts_list_request(id: String) -> JSONRPCRequest:
    """Create a prompts/list request."""
    return JSONRPCRequest(id, "prompts/list", "{}")

fn create_prompts_get_request(id: String, name: String, arguments: String = "{}") -> JSONRPCRequest:
    """Create a prompts/get request."""
    var params = String('{"name":"', name, '","arguments":', arguments, '}')
    return JSONRPCRequest(id, "prompts/get", params)

# MCP message validation functions

fn is_mcp_method(method: String) -> Bool:
    """Check if a method name is a valid MCP method."""
    return (method == "initialize" or
            method == "initialized" or
            method.startswith("tools/") or
            method.startswith("resources/") or
            method.startswith("prompts/") or
            method.startswith("logging/") or
            method.startswith("roots/") or
            method.startswith("sampling/"))

fn extract_method_category(method: String) -> String:
    """Extract the category from an MCP method name."""
    if method == "initialize" or method == "initialized":
        return "lifecycle"
    
    var slash_pos = method.find("/")
    if slash_pos != -1:
        return method[:slash_pos]
    
    return "unknown"

# Protocol version validation
fn is_compatible_version(version: String) -> Bool:
    """Check if a protocol version is compatible with this implementation."""
    return version == MCP_PROTOCOL_VERSION

@value
struct MCPMessage(Movable):
    """Wrapper for MCP messages with metadata."""
    var request_id: String
    var method: String
    var category: String
    var timestamp: Int  # Unix timestamp
    var raw_json: String
    
    fn __init__(out self, request_id: String, method: String, raw_json: String):
        self.request_id = request_id
        self.method = method
        self.category = extract_method_category(method)
        self.timestamp = 0  # TODO: Get actual timestamp
        self.raw_json = raw_json
    
    fn is_valid_mcp_message(self) -> Bool:
        """Check if this is a valid MCP message."""
        return is_mcp_method(self.method)