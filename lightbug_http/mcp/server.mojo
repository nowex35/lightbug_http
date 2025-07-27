"""MCP Server core implementation.

This module provides the main MCPServer class that manages client connections,
handles the MCP protocol lifecycle, and coordinates with the transport layer.
"""

from collections import Dict
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, JSONRPCError, method_not_found, invalid_params, internal_error, server_not_initialized, unsupported_protocol_version, tool_not_found, tool_execution_failed, feature_not_implemented, log_error
from .messages import MCPServerInfo, MCPCapabilities, create_initialize_response, MCP_PROTOCOL_VERSION, is_compatible_version
from .transport import MCPHandler
# Due to module import issues, define simplified stubs here
@value
struct MCPTool(Movable):
    var name: String
    var description: String
    var enabled: Bool
    
    fn __init__(out self, name: String = "", description: String = "", enabled: Bool = True):
        self.name = name
        self.description = description
        self.enabled = enabled
    
    fn to_json(self) -> String:
        return String('{"name":"', self.name, '","description":"', self.description, '","enabled":', String(self.enabled), '}')

@value
struct MCPToolResult(Movable):
    var is_error: Bool
    var content: String
    
    fn __init__(out self, is_error: Bool = False, content: String = ""):
        self.is_error = is_error
        self.content = content
    
    fn to_json(self) -> String:
        return String('{"content":"', self.content, '","isError":', String(self.is_error), '}')

@value
struct MCPToolRegistry(Movable):
    var enabled: Bool
    
    fn __init__(out self):
        self.enabled = True
    
    fn register_tool(mut self, tool: MCPTool, executor: fn(String) raises -> MCPToolResult) raises:
        print("Tool registered: " + tool.name)
    
    fn unregister_tool(mut self, tool_name: String) raises:
        print("Tool unregistered: " + tool_name)
    
    fn list_tools(self) -> List[MCPTool]:
        return List[MCPTool]()
    
    fn execute_tool(mut self, tool_name: String, arguments_json: String) raises -> MCPToolResult:
        return MCPToolResult(False, "Tool execution not implemented")

# Connection states
alias ConnectionState = Int
alias DISCONNECTED: ConnectionState = 0
alias CONNECTING: ConnectionState = 1
alias INITIALIZING: ConnectionState = 2
alias INITIALIZED: ConnectionState = 3
alias READY: ConnectionState = 4
alias ERROR: ConnectionState = 5

@value
struct MCPConnection(Movable):
    """Represents a client connection to the MCP server."""
    var connection_id: String
    var state: ConnectionState
    var protocol_version: String
    var client_name: String
    var client_version: String
    var client_capabilities: MCPCapabilities
    var session_start_time: Int  # Unix timestamp
    
    fn __init__(out self, connection_id: String):
        self.connection_id = connection_id
        self.state = CONNECTING
        self.protocol_version = ""
        self.client_name = ""
        self.client_version = ""
        self.client_capabilities = MCPCapabilities()
        self.session_start_time = 0  # TODO: Get actual timestamp
    
    fn is_initialized(self) -> Bool:
        """Check if the connection has completed initialization."""
        return self.state >= INITIALIZED
    
    fn is_ready(self) -> Bool:
        """Check if the connection is ready for normal operations."""
        return self.state == READY

@value
struct MCPServer:
    """Main MCP server implementation.
    
    This server handles:
    - Connection lifecycle management
    - Protocol version negotiation
    - Capability negotiation
    - Request routing to appropriate handlers
    """
    
    var server_info: MCPServerInfo
    var server_capabilities: MCPCapabilities
    var connections: Dict[String, MCPConnection]
    var tools_registry: MCPToolRegistry
    var tools_handler: ToolsHandler
    var resources_handler: ResourcesHandler
    var prompts_handler: PromptsHandler
    var is_running: Bool
    
    fn __init__(out self, 
                server_name: String = "lightbug-mcp-server",
                server_version: String = "1.0.0"):
        self.server_info = MCPServerInfo(server_name, server_version)
        # Enable only tools capability (resources and prompts postponed)
        self.server_capabilities = MCPCapabilities(
            tools=True, 
            resources=False, 
            prompts=False, 
            logging=True
        )
        self.connections = Dict[String, MCPConnection]()
        self.tools_registry = MCPToolRegistry()
        self.tools_handler = ToolsHandler(self.tools_registry)
        self.resources_handler = ResourcesHandler()
        self.prompts_handler = PromptsHandler()
        self.is_running = False
    
    fn start(mut self) raises:
        """Start the MCP server."""
        if self.is_running:
            raise Error("Server is already running")
        
        self.is_running = True
        print("MCP Server started: " + self.server_info.name + " v" + self.server_info.version)
    
    fn stop(mut self) raises:
        """Stop the MCP server and close all connections."""
        if not self.is_running:
            return
        
        # Close all active connections - collect IDs first to avoid aliasing issues
        var connection_ids = List[String]()
        for connection_id in self.connections:
            connection_ids.append(connection_id)
        
        for i in range(len(connection_ids)):
            self._close_connection(connection_ids[i])
        
        self.is_running = False
        print("MCP Server stopped")
    
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle incoming JSON-RPC requests."""
        if not self.is_running:
            var error = server_not_initialized()
            log_error(error, "handle_request")
            return JSONRPCResponse.error_response(request.id, error)
        
        # Route request based on method
        if request.method == "initialize":
            return self._handle_initialize(request)
        elif request.method.startswith("tools/"):
            return self._handle_tools_request(request)
        elif request.method.startswith("resources/"):
            return self._handle_resources_request(request)
        elif request.method.startswith("prompts/"):
            return self._handle_prompts_request(request)
        else:
            var error = method_not_found()
            return JSONRPCResponse.error_response(request.id, error)
    
    fn handle_notification(mut self, notification: JSONRPCNotification) raises:
        """Handle incoming JSON-RPC notifications."""
        if not self.is_running:
            return
        
        if notification.method == "initialized":
            self._handle_initialized(notification)
        elif notification.method.startswith("notifications/"):
            # Handle various notification types
            pass
    
    fn _handle_initialize(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle the initialize request from a client."""
        try:
            # Extract connection ID from request (or generate one)
            var connection_id = self._generate_connection_id()
            
            # Parse initialization parameters
            var init_params = self._parse_initialize_params(request.params)
            
            # Validate protocol version
            if not is_compatible_version(init_params.protocol_version):
                var error = unsupported_protocol_version(init_params.protocol_version)
                log_error(error, "initialize")
                return JSONRPCResponse.error_response(request.id, error)
            
            # Validate client capabilities compatibility
            var negotiated_capabilities = self._negotiate_capabilities(init_params.client_capabilities)
            
            # Create new connection
            var connection = MCPConnection(connection_id)
            connection.state = INITIALIZING
            connection.protocol_version = init_params.protocol_version
            connection.client_name = init_params.client_name
            connection.client_version = init_params.client_version
            connection.client_capabilities = init_params.client_capabilities
            
            # Store the connection
            self.connections[connection_id] = connection
            
            # Create initialize response with negotiated capabilities
            var response = create_initialize_response(
                request.id, 
                self.server_info, 
                negotiated_capabilities
            )
            
            print("Client initialized: " + connection.client_name + " v" + connection.client_version)
            print("Negotiated capabilities - Tools: " + String(negotiated_capabilities.tools) + 
                  ", Resources: " + String(negotiated_capabilities.resources) + 
                  ", Prompts: " + String(negotiated_capabilities.prompts))
            return response
            
        except e:
            var error = internal_error()
            log_error(error, "initialize_failed")
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _handle_initialized(mut self, notification: JSONRPCNotification) raises:
        """Handle the initialized notification from a client."""
        # Mark all initializing connections as ready
        for connection_id in self.connections:
            var connection = self.connections[connection_id]
            if connection.state == INITIALIZING:
                connection.state = READY
                self.connections[connection_id] = connection
                print("Client ready: " + connection.client_name)
    
    fn _handle_tools_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/* requests."""
        return self.tools_handler.handle_request(request)
    
    fn _handle_resources_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources/* requests."""
        return self.resources_handler.handle_request(request)
    
    fn _handle_prompts_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle prompts/* requests."""
        return self.prompts_handler.handle_request(request)
    
    fn _generate_connection_id(self) -> String:
        """Generate a unique connection ID."""
        # TODO: Implement proper UUID generation
        return "2d7a1cdd-a254-477a-8872-6b09cc5253c3"
    
    fn _parse_initialize_params(self, params_json: String) raises -> InitializeParams:
        """Parse initialize request parameters."""
        # TODO: Implement proper JSON parsing
        return InitializeParams()
    
    fn _close_connection(mut self, connection_id: String) raises:
        """Close a client connection."""
        if connection_id in self.connections:
            var connection = self.connections[connection_id]
            print("Closing connection: " + connection.client_name)
            _ = self.connections.pop(connection_id)
    
    fn get_connection_count(self) -> Int:
        """Get the number of active connections."""
        return len(self.connections)
    
    fn get_server_info(self) -> MCPServerInfo:
        """Get server information."""
        return self.server_info
    
    fn get_server_capabilities(self) -> MCPCapabilities:
        """Get server capabilities."""
        return self.server_capabilities
    
    fn _negotiate_capabilities(self, client_capabilities: MCPCapabilities) -> MCPCapabilities:
        """Negotiate capabilities between server and client.
        
        Returns the intersection of server and client capabilities.
        Only features supported by both sides will be enabled.
        """
        var negotiated = MCPCapabilities()
        
        # Tools capability negotiation
        negotiated.tools = self.server_capabilities.tools and client_capabilities.tools
        
        # Resources capability negotiation (currently disabled on server side)  
        negotiated.resources = self.server_capabilities.resources and client_capabilities.resources
        
        # Prompts capability negotiation (currently disabled on server side)
        negotiated.prompts = self.server_capabilities.prompts and client_capabilities.prompts
        
        # Logging capability negotiation
        negotiated.logging = self.server_capabilities.logging and client_capabilities.logging
        
        # Roots capability negotiation  
        negotiated.roots = self.server_capabilities.roots and client_capabilities.roots
        
        # Sampling capability negotiation
        negotiated.sampling = self.server_capabilities.sampling and client_capabilities.sampling
        
        return negotiated
    
    fn is_capability_enabled(self, connection_id: String, capability: String) raises -> Bool:
        """Check if a specific capability is enabled for a connection."""
        if connection_id not in self.connections:
            return False
            
        var connection = self.connections[connection_id]
        if not connection.is_ready():
            return False
        
        # Check negotiated capabilities based on capability string
        if capability == "tools":
            return connection.client_capabilities.tools and self.server_capabilities.tools
        elif capability == "resources":
            return connection.client_capabilities.resources and self.server_capabilities.resources
        elif capability == "prompts":
            return connection.client_capabilities.prompts and self.server_capabilities.prompts
        elif capability == "logging":
            return connection.client_capabilities.logging and self.server_capabilities.logging
        elif capability == "roots":
            return connection.client_capabilities.roots and self.server_capabilities.roots
        elif capability == "sampling":
            return connection.client_capabilities.sampling and self.server_capabilities.sampling
        
        return False
    
    fn update_server_capabilities(mut self, capabilities: MCPCapabilities) raises:
        """Update server capabilities. Can only be called when server is stopped."""
        if self.is_running:
            raise Error("Cannot update capabilities while server is running")
        
        self.server_capabilities = capabilities
        print("Server capabilities updated")
    
    fn get_negotiated_capabilities(self, connection_id: String) raises -> MCPCapabilities:
        """Get negotiated capabilities for a specific connection."""
        if connection_id not in self.connections:
            return MCPCapabilities()  # Return empty capabilities for non-existent connection
            
        var connection = self.connections[connection_id]
        return self._negotiate_capabilities(connection.client_capabilities)
    
    fn register_tool(mut self, tool: MCPTool, executor: fn(String) raises -> MCPToolResult) raises:
        """Register a new tool with the server."""
        self.tools_registry.register_tool(tool, executor)
    
    fn unregister_tool(mut self, tool_name: String) raises:
        """Unregister a tool from the server."""
        self.tools_registry.unregister_tool(tool_name)
    
    fn get_tools_registry(mut self) -> MCPToolRegistry:
        """Get the tools registry for advanced operations."""
        return self.tools_registry

# Helper structure for initialize parameters
@value
struct InitializeParams(Movable):
    """Parameters for the initialize request."""
    var protocol_version: String
    var client_name: String
    var client_version: String
    var client_capabilities: MCPCapabilities
    
    fn __init__(out self):
        self.protocol_version = MCP_PROTOCOL_VERSION
        self.client_name = "unknown"
        self.client_version = "unknown"
        self.client_capabilities = MCPCapabilities()

# Forward declarations for handlers
trait RequestHandler:
    """Base trait for MCP request handlers."""
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        pass

@value
struct ToolsHandler(RequestHandler):
    """Handler for tools/* requests."""
    var tools_registry: MCPToolRegistry
    
    fn __init__(out self, tools_registry: MCPToolRegistry):
        self.tools_registry = tools_registry
    
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools requests."""
        if request.method == "tools/list":
            return self._handle_tools_list(request)
        elif request.method == "tools/call":
            return self._handle_tools_call(request)
        else:
            var error = method_not_found()
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _handle_tools_list(self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/list request."""
        var tools = self.tools_registry.list_tools()
        var tools_json = String("{" + "tools" + ":[")
        
        for i in range(len(tools)):
            if i > 0:
                tools_json = tools_json + ","
            tools_json = tools_json + tools[i].to_json()
        
        tools_json = tools_json + "]}"
        return JSONRPCResponse.success(request.id, tools_json)
    
    fn _handle_tools_call(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/call request."""
        try:
            # Parse tool name and arguments from request params
            var tool_info = self._parse_tool_call_params(request.params)
            
            # Execute the tool
            var result = self.tools_registry.execute_tool(tool_info.name, tool_info.arguments)
            
            # Return the result
            return JSONRPCResponse.success(request.id, result.to_json())
            
        except e:
            var error = tool_execution_failed("unknown", "execution error")
            log_error(error, "tools_call")
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _parse_tool_call_params(self, params_json: String) raises -> ToolCallParams:
        """Parse tool call parameters from JSON."""
        # TODO: Implement proper JSON parsing
        # For now, return default values
        return ToolCallParams()

@value
struct ToolCallParams(Movable):
    """Parameters for tool call request."""
    var name: String
    var arguments: String
    
    fn __init__(out self, name: String = "unknown", arguments: String = "{}"):
        self.name = name
        self.arguments = arguments

@value
struct ResourcesHandler(RequestHandler):
    """Handler for resources/* requests."""
    
    fn __init__(out self):
        pass
    
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources requests - currently postponed."""
        var error: JSONRPCError
        
        if request.method == "resources/list":
            error = JSONRPCError(-32601, "resources/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/read":
            error = JSONRPCError(-32601, "resources/read method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/updated":
            error = JSONRPCError(-32601, "resources/updated notification is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown resources method: " + request.method + ". Resources feature is postponed for future implementation.")
        
        return JSONRPCResponse.error_response(request.id, error)

@value
struct PromptsHandler(RequestHandler):
    """Handler for prompts/* requests."""
    
    fn __init__(out self):
        pass
    
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle prompts requests - currently postponed."""
        var error: JSONRPCError
        
        if request.method == "prompts/list":
            error = JSONRPCError(-32601, "prompts/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "prompts/get":
            error = JSONRPCError(-32601, "prompts/get method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "prompts/updated":
            error = JSONRPCError(-32601, "prompts/updated notification is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown prompts method: " + request.method + ". Prompts feature is postponed for future implementation.")
        
        return JSONRPCResponse.error_response(request.id, error)

# Utility function for creating MCP servers
fn create_mcp_server(name: String = "lightbug-mcp-server", 
                    version: String = "1.0.0") -> MCPServer:
    """Create a new MCP server with default configuration."""
    return MCPServer(name, version)