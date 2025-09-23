"""MCP Server core implementation.

This module provides the main MCPServer class that manages client connections,
handles the MCP protocol lifecycle, and coordinates with the transport layer.
"""

from collections import Dict
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, JSONRPCError, method_not_found, invalid_params, internal_error, server_not_initialized, unsupported_protocol_version, tool_not_found, tool_execution_failed, feature_not_implemented, log_error
from .messages import MCPServerInfo, MCPCapabilities, create_initialize_response, MCP_PROTOCOL_VERSION, is_compatible_version
from .transport import MCPHandler
from .session import SessionManager, MCPSession
from .tools import MCPTool, MCPToolResult, MCPToolRegistry, ToolExecutionFunc, create_string_parameter
from .utils import generate_connection_id

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
struct MCPServer(MCPHandler):
    """Main MCP server implementation.
    
    This server handles:
    - Connection lifecycle management
    - Protocol version negotiation
    - Capability negotiation
    - Request routing to appropriate handlers
    - Session management with timeout monitoring
    """
    
    var server_info: MCPServerInfo
    var server_capabilities: MCPCapabilities
    var connections: Dict[String, MCPConnection]
    var session_manager: SessionManager
    var tools_registry: MCPToolRegistry
    var tools_handler: ToolsHandler
    var resources_handler: ResourcesHandler
    var prompts_handler: PromptsHandler
    var templates_handler: TemplatesHandler
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
        self.session_manager = SessionManager()
        self.tools_registry = MCPToolRegistry()
        self.tools_handler = ToolsHandler(self.tools_registry)
        self.resources_handler = ResourcesHandler()
        self.prompts_handler = PromptsHandler()
        self.templates_handler = TemplatesHandler()
        self.is_running = False
    
    fn start(mut self) raises:
        """Start the MCP server."""
        if self.is_running:
            raise Error("Server is already running")
        
        self.is_running = True
    
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
        elif request.method.startswith("resources/templates/"):
            return self._handle_templates_request(request)
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
    
    fn handle_request_with_session(mut self, request: JSONRPCRequest, session_id: String) raises -> JSONRPCResponse:
        """Handle incoming JSON-RPC requests with session management."""
        if not self.is_running:
            var error = server_not_initialized()
            log_error(error, "handle_request_with_session")
            return JSONRPCResponse.error_response(request.id, error)
        
        # Perform session cleanup
        _ = self.session_manager.cleanup_expired_sessions()
        
        # Handle session-aware request
        if request.method == "initialize":
            return self._handle_initialize_with_session(request, session_id)
        else:
            # For other requests, validate session if provided
            if session_id != "":
                try:
                    self.session_manager.update_session_activity(session_id)
                except:
                    # Invalid session ID, continue with regular handling
                    pass
            
            # Delegate to regular handler
            return self.handle_request(request)
    
    fn handle_notification_with_session(mut self, notification: JSONRPCNotification, session_id: String) raises:
        """Handle incoming JSON-RPC notifications with session management."""
        if not self.is_running:
            return
        
        # Update session activity if session exists
        if session_id != "":
            try:
                self.session_manager.update_session_activity(session_id)
            except:
                # Invalid session ID, continue with regular handling
                pass
        
        # Delegate to regular handler
        self.handle_notification(notification)
    
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
            var _ = self._negotiate_capabilities(init_params.client_capabilities)
            
            # Create new connection
            var connection = MCPConnection(connection_id)
            connection.state = INITIALIZING
            connection.protocol_version = init_params.protocol_version
            connection.client_name = init_params.client_name
            connection.client_version = init_params.client_version
            connection.client_capabilities = init_params.client_capabilities
            
            # Store the connection
            self.connections[connection_id] = connection
            
            # Create initialize response with server capabilities
            var response = create_initialize_response(
                request.id,
                self.server_info,
                self.server_capabilities
            )
            return response
            
        except e:
            var error = internal_error()
            log_error(error, "initialize_failed")
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _handle_initialize_with_session(mut self, request: JSONRPCRequest, session_id: String) raises -> JSONRPCResponse:
        """Handle the initialize request with session management."""
        try:
            # Extract connection ID from request (or generate one)
            var connection_id = self._generate_connection_id()
            
            # Parse initialization parameters
            var init_params = self._parse_initialize_params(request.params)
            
            # Validate protocol version
            if not is_compatible_version(init_params.protocol_version):
                var error = unsupported_protocol_version(init_params.protocol_version)
                log_error(error, "initialize_with_session")
                return JSONRPCResponse.error_response(request.id, error)
            
            # Create or manage session
            var _ = session_id
            if session_id == "":
                # No session ID provided, create a new session
                var client_info = String('{"name":"', init_params.client_name, '","version":"', init_params.client_version, '"}')
                var _ = self.session_manager.create_session(connection_id, client_info)
            else:
                # Session ID provided, validate and update
                try:
                    var session = self.session_manager.get_session(session_id)
                    if session.connection_id != connection_id:
                        # Associate session with new connection
                        self.session_manager.terminate_session_by_connection(session.connection_id)
                        var client_info = String('{"name":"', init_params.client_name, '","version":"', init_params.client_version, '"}')
                        var _ = self.session_manager.create_session(connection_id, client_info)
                    else:
                        self.session_manager.update_session_activity(session_id)
                except:
                    # Invalid session, create new one
                    var client_info = String('{"name":"', init_params.client_name, '","version":"', init_params.client_version, '"}')
                    var _ = self.session_manager.create_session(connection_id, client_info)
            
            # Validate client capabilities compatibility
            var _ = self._negotiate_capabilities(init_params.client_capabilities)
            
            # Create new connection
            var connection = MCPConnection(connection_id)
            connection.state = INITIALIZING
            connection.protocol_version = init_params.protocol_version
            connection.client_name = init_params.client_name
            connection.client_version = init_params.client_version
            connection.client_capabilities = init_params.client_capabilities
            
            # Store the connection
            self.connections[connection_id] = connection
            
            # Create initialize response with server capabilities and session ID
            var response = create_initialize_response(
                request.id,
                self.server_info,
                self.server_capabilities
            )
            
            return response
            
        except e:
            var error = internal_error()
            log_error(error, "initialize_with_session_failed")
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _handle_initialized(mut self, notification: JSONRPCNotification) raises:
        """Handle the initialized notification from a client."""
        # Mark all initializing connections as ready
        for connection_id in self.connections:
            var connection = self.connections[connection_id]
            if connection.state == INITIALIZING:
                connection.state = READY
                self.connections[connection_id] = connection
    
    fn _handle_tools_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/* requests."""
        
        if request.method == "tools/list":
            var tools = self.tools_registry.list_tools()
            
            # Build tools array
            var tools_array = String("[")
            var added_count = 0
            
            for i in range(len(tools)):
                try:
                    var tool_json = tools[i].to_json()
                    if added_count > 0:
                        tools_array = tools_array + ","
                    tools_array = tools_array + tool_json
                    added_count += 1
                except e:
                    continue
            
            tools_array = tools_array + "]"
            
            # Create proper MCP response format with result object
            var result_json = String('{"tools":' + tools_array + '}')
            var response = JSONRPCResponse.success(request.id, result_json)
            return response
        elif request.method == "tools/call":
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
        else:
            var error = method_not_found()
            return JSONRPCResponse.error_response(request.id, error)
    
    fn _handle_resources_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources/* requests."""
        return self.resources_handler.handle_request(request)
    
    fn _handle_prompts_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle prompts/* requests."""
        return self.prompts_handler.handle_request(request)
    
    fn _handle_templates_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources/templates/* requests."""
        return self.templates_handler.handle_request(request)
    
    fn _generate_connection_id(self) -> String:
        """Generate a unique connection ID."""
        return generate_connection_id()
    
    fn _parse_initialize_params(self, params_json: String) raises -> InitializeParams:
        """Parse initialize request parameters."""
        
        var params = InitializeParams()
        
        # Extract protocolVersion (handle both single and double quotes)
        var protocol_start = params_json.find("'protocolVersion'")
        if protocol_start == -1:
            protocol_start = params_json.find('"protocolVersion"')
        
        if protocol_start != -1:
            var protocol_colon = params_json.find(':', protocol_start)
            if protocol_colon != -1:
                var protocol_quote_start = params_json.find("'", protocol_colon)
                var quote_char = String("'")
                if protocol_quote_start == -1:
                    protocol_quote_start = params_json.find('"', protocol_colon)
                    quote_char = String('"')
                
                if protocol_quote_start != -1:
                    var protocol_quote_end = params_json.find(quote_char, protocol_quote_start + 1)
                    if protocol_quote_end != -1:
                        params.protocol_version = params_json[protocol_quote_start + 1:protocol_quote_end]
        
        # Extract clientInfo.name (handle both quote types)
        var client_info_start = params_json.find("'clientInfo'")
        if client_info_start == -1:
            client_info_start = params_json.find('"clientInfo"')
            
        if client_info_start != -1:
            var name_start = params_json.find("'name'", client_info_start)
            if name_start == -1:
                name_start = params_json.find('"name"', client_info_start)
                
            if name_start != -1:
                var name_colon = params_json.find(':', name_start)
                if name_colon != -1:
                    var name_quote_start = params_json.find("'", name_colon)
                    var name_quote_char = String("'")
                    if name_quote_start == -1:
                        name_quote_start = params_json.find('"', name_colon)
                        name_quote_char = String('"')
                        
                    if name_quote_start != -1:
                        var name_quote_end = params_json.find(name_quote_char, name_quote_start + 1)
                        if name_quote_end != -1:
                            params.client_name = params_json[name_quote_start + 1:name_quote_end]
            
            # Extract clientInfo.version (handle both quote types)
            var version_start = params_json.find("'version'", client_info_start)
            if version_start == -1:
                version_start = params_json.find('"version"', client_info_start)
                
            if version_start != -1:
                var version_colon = params_json.find(':', version_start)
                if version_colon != -1:
                    var version_quote_start = params_json.find("'", version_colon)
                    var version_quote_char = String("'")
                    if version_quote_start == -1:
                        version_quote_start = params_json.find('"', version_colon)
                        version_quote_char = String('"')
                        
                    if version_quote_start != -1:
                        var version_quote_end = params_json.find(version_quote_char, version_quote_start + 1)
                        if version_quote_end != -1:
                            params.client_version = params_json[version_quote_start + 1:version_quote_end]
        
        return params
    
    fn _close_connection(mut self, connection_id: String) raises:
        """Close a client connection."""
        if connection_id in self.connections:
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
    
    fn register_tool(mut self, tool: MCPTool, executor: ToolExecutionFunc) raises:
        """Register a new tool with the server."""
        self.tools_registry.register_tool(tool, executor)
        var _ = self.tools_registry.list_tools()
    
    fn unregister_tool(mut self, tool_name: String) raises:
        """Unregister a tool from the server."""
        self.tools_registry.unregister_tool(tool_name)
    
    fn get_tools_registry(mut self) -> MCPToolRegistry:
        """Get the tools registry for advanced operations."""
        return self.tools_registry
    
    fn get_active_session_count(self) -> Int:
        """Get the number of active sessions."""
        return self.session_manager.get_active_session_count()
    
    fn cleanup_expired_sessions(mut self) -> Int:
        """Force cleanup of expired sessions and return the number cleaned."""
        return self.session_manager.force_cleanup()
    
    fn terminate_session(mut self, session_id: String) raises:
        """Terminate a specific session."""
        self.session_manager.terminate_session(session_id)
    
    fn _parse_tool_call_params(self, params_json: String) raises -> ToolCallParams:
        """Parse tool call parameters from JSON."""
        # Expected format: {"name": "tool_name", "arguments": {...}}        
        # Simple JSON parsing for tool call parameters
        var name = String("unknown")
        var arguments = String("{}")
        
        # Extract tool name - handle both single and double quotes
        var name_start = params_json.find("'name'")
        if name_start == -1:
            name_start = params_json.find('"name"')
        
        if name_start != -1:
            var name_colon = params_json.find(':', name_start)
            if name_colon != -1:
                # Look for either single or double quote
                var name_quote_start = params_json.find("'", name_colon)
                var quote_char = String("'")
                if name_quote_start == -1:
                    name_quote_start = params_json.find('"', name_colon)
                    quote_char = String('"')
                
                if name_quote_start != -1:
                    var name_quote_end = params_json.find(quote_char, name_quote_start + 1)
                    if name_quote_end != -1:
                        name = params_json[name_quote_start + 1:name_quote_end]
        
        # Extract arguments object - handle both single and double quotes
        var args_start = params_json.find("'arguments'")
        if args_start == -1:
            args_start = params_json.find('"arguments"')
        
        if args_start != -1:
            var args_colon = params_json.find(':', args_start)
            if args_colon != -1:
                # Find the opening brace of the arguments object
                var args_brace_start = params_json.find('{', args_colon)
                if args_brace_start != -1:
                    # Find the matching closing brace
                    var brace_count = 1
                    var pos = args_brace_start + 1
                    var args_end = -1
                    
                    while pos < len(params_json) and brace_count > 0:
                        if params_json[pos] == '{':
                            brace_count += 1
                        elif params_json[pos] == '}':
                            brace_count -= 1
                            if brace_count == 0:
                                args_end = pos + 1
                                break
                        pos += 1
                    
                    if args_end != -1:
                        arguments = params_json[args_brace_start:args_end]
                        # Convert single quotes to double quotes for valid JSON
                        arguments = arguments.replace("'", '"')
                
        return ToolCallParams(name, arguments)

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
        
        # Build tools array
        var tools_array = String("[")
        var added_count = 0
        
        for i in range(len(tools)):
            try:
                var tool_json = tools[i].to_json()
                if added_count > 0:
                    tools_array = tools_array + ","
                tools_array = tools_array + tool_json
                added_count += 1
            except e:
                continue
        
        tools_array = tools_array + "]"
        
        # Create proper MCP response format with result object
        var result_json = String('{"tools":' + tools_array + '}')
        return JSONRPCResponse.success(request.id, result_json)
    
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
        # Expected format: {"name": "tool_name", "arguments": {...}}
                
        # Simple JSON parsing for tool call parameters
        var name = String("unknown")
        var arguments = String("{}")
        
        # Extract tool name - handle both single and double quotes
        var name_start = params_json.find("'name'")
        if name_start == -1:
            name_start = params_json.find('"name"')
        
        if name_start != -1:
            var name_colon = params_json.find(':', name_start)
            if name_colon != -1:
                # Look for either single or double quote
                var name_quote_start = params_json.find("'", name_colon)
                var quote_char = String("'")
                if name_quote_start == -1:
                    name_quote_start = params_json.find('"', name_colon)
                    quote_char = String('"')
                
                if name_quote_start != -1:
                    var name_quote_end = params_json.find(quote_char, name_quote_start + 1)
                    if name_quote_end != -1:
                        name = params_json[name_quote_start + 1:name_quote_end]
                        
        
        # Extract arguments object - handle both single and double quotes
        var args_start = params_json.find("'arguments'")
        if args_start == -1:
            args_start = params_json.find('"arguments"')
        
        if args_start != -1:
            var args_colon = params_json.find(':', args_start)
            if args_colon != -1:
                # Find the opening brace of the arguments object
                var args_brace_start = params_json.find('{', args_colon)
                if args_brace_start != -1:
                    # Find the matching closing brace
                    var brace_count = 1
                    var pos = args_brace_start + 1
                    var args_end = -1
                    
                    while pos < len(params_json) and brace_count > 0:
                        if params_json[pos] == '{':
                            brace_count += 1
                        elif params_json[pos] == '}':
                            brace_count -= 1
                            if brace_count == 0:
                                args_end = pos + 1
                                break
                        pos += 1
                    
                    if args_end != -1:
                        arguments = params_json[args_brace_start:args_end]
                        # Convert single quotes to double quotes for valid JSON
                        arguments = arguments.replace("'", '"')
        
        return ToolCallParams(name, arguments)

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

@value
struct TemplatesHandler(RequestHandler):
    """Handler for resources/templates/* requests."""
    
    fn __init__(out self):
        pass
    
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle templates requests - currently postponed."""
        var error: JSONRPCError
        
        if request.method == "resources/templates/list":
            error = JSONRPCError(-32601, "resources/templates/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/templates/read":
            error = JSONRPCError(-32601, "resources/templates/read method is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown templates method: " + request.method + ". Templates feature is postponed for future implementation.")
        
        return JSONRPCResponse.error_response(request.id, error)


# Utility function for creating MCP servers
fn create_mcp_server(name: String = "lightbug-mcp-server", 
                    version: String = "1.0.0") -> MCPServer:
    """Create a new MCP server with default configuration."""
    return MCPServer(name, version)