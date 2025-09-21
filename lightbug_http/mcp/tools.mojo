"""MCP Tools system implementation.

This module provides the tools system for MCP servers, including tool definitions,
registration, parameter validation, and execution.
"""

from collections import Dict, List

# Local type definitions to avoid circular imports
@value
struct JSONRPCError(Movable):
    var code: Int
    var message: String
    var data: String
    
    fn __init__(out self, code: Int, message: String, data: String = ""):
        self.code = code
        self.message = message
        self.data = data

# Tool input schema types
alias MCPToolInputType = String
alias TOOL_TYPE_STRING: MCPToolInputType = "string"
alias TOOL_TYPE_NUMBER: MCPToolInputType = "number"
alias TOOL_TYPE_BOOLEAN: MCPToolInputType = "boolean"
alias TOOL_TYPE_OBJECT: MCPToolInputType = "object"
alias TOOL_TYPE_ARRAY: MCPToolInputType = "array"

@value
struct MCPToolParameter(Movable):
    """A tool parameter definition with JSON Schema validation."""
    var name: String
    var type: MCPToolInputType
    var description: String
    var required: Bool
    var default_value: String  # JSON string representation
    var enum_values: List[String]  # For enum validation
    
    fn __init__(out self, name: String, type: MCPToolInputType, 
                description: String, required: Bool = True,
                default_value: String = "", enum_values: List[String] = List[String]()):
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.default_value = default_value
        self.enum_values = enum_values
    
    fn to_json(self) -> String:
        """Convert parameter to JSON Schema format."""
        var json = String('{"type":"', self.type, '","description":"', self.description, '"')
        
        # Add enum values if present
        if len(self.enum_values) > 0:
            json = json + ',"enum":['
            for i in range(len(self.enum_values)):
                if i > 0:
                    json = json + ","
                json = json + '"' + self.enum_values[i] + '"'
            json = json + "]"
        
        # Add default value if present
        if self.default_value != "":
            json = json + ',"default":' + self.default_value
        
        json = json + "}"
        return json

@value
struct MCPToolAnnotation(Movable):
    """Annotation for a tool describing its behavior and constraints."""
    var audience: List[String]  # Who can use this tool
    var danger_level: String    # "safe", "warning", "dangerous"
    var rate_limit: Int         # Requests per minute (0 = no limit)
    var requires_auth: Bool     # Whether authentication is required
    var tags: List[String]      # Tags for categorization
    
    fn __init__(out self, danger_level: String = "safe", rate_limit: Int = 0, 
                requires_auth: Bool = False):
        self.audience = List[String]()
        self.danger_level = danger_level
        self.rate_limit = rate_limit
        self.requires_auth = requires_auth
        self.tags = List[String]()
    
    fn add_audience(mut self, audience: String):
        """Add an audience member."""
        self.audience.append(audience)
    
    fn add_tag(mut self, tag: String):
        """Add a tag."""
        self.tags.append(tag)

@value
struct MCPTool(Movable):
    """Definition of an MCP tool with its metadata and parameters."""
    var name: String
    var description: String
    var input_schema: Dict[String, MCPToolParameter]
    var required_params: List[String]
    var category: String  # For organization
    var version: String
    var enabled: Bool
    var annotations: MCPToolAnnotation  # Tool annotations
    
    fn __init__(out self, name: String, description: String, category: String = "general", 
                version: String = "1.0.0", enabled: Bool = True):
        self.name = name
        self.description = description
        self.input_schema = Dict[String, MCPToolParameter]()
        self.required_params = List[String]()
        self.category = category
        self.version = version
        self.enabled = enabled
        self.annotations = MCPToolAnnotation()
    
    fn add_parameter(mut self, param: MCPToolParameter):
        """Add a parameter to this tool."""
        self.input_schema[param.name] = param
        if param.required:
            self.required_params.append(param.name)
    
    fn to_json(self) raises -> String:
        """Convert tool definition to MCP JSON format."""
        var json = String('{"name":"', self.name, '","description":"', self.description, '"')
        
        # Add input schema
        json = json + ',"inputSchema":{"type":"object","properties":{'
        var first = True
        for param_name in self.input_schema:
            if not first:
                json = json + ","
            var param = self.input_schema[param_name]
            json = json + '"' + param_name + '":' + param.to_json()
            first = False
        
        json = json + "}}"
        
        # Add required parameters
        if len(self.required_params) > 0:
            json = json + ',"required":['
            for i in range(len(self.required_params)):
                if i > 0:
                    json = json + ","
                json = json + '"' + self.required_params[i] + '"'
            json = json + "]"
        
        # Add annotations
        json = json + ',"annotations":{'
        json = json + '"dangerLevel":"' + self.annotations.danger_level + '"'
        json = json + ',"rateLimit":' + String(self.annotations.rate_limit)
        json = json + ',"requiresAuth":' + String(self.annotations.requires_auth)
        
        if len(self.annotations.audience) > 0:
            json = json + ',"audience":['
            for i in range(len(self.annotations.audience)):
                if i > 0:
                    json = json + ","
                json = json + '"' + self.annotations.audience[i] + '"'
            json = json + "]"
        
        if len(self.annotations.tags) > 0:
            json = json + ',"tags":['
            for i in range(len(self.annotations.tags)):
                if i > 0:
                    json = json + ","
                json = json + '"' + self.annotations.tags[i] + '"'
            json = json + "]"
        
        json = json + "}"
        json = json + "}"
        return json
    
    fn validate_arguments(self, arguments_json: String) raises -> ValidationResult:
        """Validate provided arguments against the tool's schema."""
        var result = ValidationResult()
        
        # Parse JSON arguments (simplified parsing)
        var parsed_args = self._parse_json_arguments(arguments_json)
        
        # Check required parameters
        for required_param in self.required_params:
            if required_param not in parsed_args:
                result.add_error("Missing required parameter: " + required_param)
        
        # Validate parameter types and constraints
        for param_name in parsed_args:
            if param_name in self.input_schema:
                var param_def = self.input_schema[param_name]
                var param_value = parsed_args[param_name]
                
                var param_validation = self._validate_parameter(param_def, param_value)
                if not param_validation.is_valid:
                    result.add_error("Parameter '" + param_name + "': " + param_validation.error_message)
            else:
                result.add_warning("Unknown parameter: " + param_name)
        
        return result
    
    fn _parse_json_arguments(self, arguments_json: String) -> Dict[String, String]:
        """Parse JSON arguments into a simple key-value map."""
        var args = Dict[String, String]()
        
        # Simplified JSON parsing - extract key-value pairs
        # This is a basic implementation; in production, use a proper JSON parser
        var json_str = arguments_json.strip()
        if json_str.startswith("{") and json_str.endswith("}"):
            json_str = json_str[1:-1]  # Remove braces
            
            var pairs = json_str.split(",")
            for i in range(len(pairs)):
                var pair = pairs[i].strip()
                if ":" in pair:
                    var parts = pair.split(":", 1)
                    if len(parts) >= 2:
                        var key = String(parts[0].strip().strip('"'))
                        var value = String(parts[1].strip())
                        args[key] = value
        
        return args
    
    fn _validate_parameter(self, param_def: MCPToolParameter, value: String) -> ParameterValidationResult:
        """Validate a single parameter against its definition."""
        var result = ParameterValidationResult()
        
        # Remove quotes from string values
        var clean_value = String(value.strip().strip('"'))
        
        # Type validation
        if param_def.type == TOOL_TYPE_STRING:
            # String validation - already clean
            pass
        elif param_def.type == TOOL_TYPE_NUMBER:
            # Number validation
            if not self._is_number(clean_value):
                result.is_valid = False
                result.error_message = "Expected number, got: " + clean_value
                return result
        elif param_def.type == TOOL_TYPE_BOOLEAN:
            # Boolean validation
            if clean_value != "true" and clean_value != "false":
                result.is_valid = False
                result.error_message = "Expected boolean (true/false), got: " + clean_value
                return result
        
        # Enum validation
        if len(param_def.enum_values) > 0:
            var valid_enum = False
            for enum_value in param_def.enum_values:
                if clean_value == enum_value:
                    valid_enum = True
                    break
            
            if not valid_enum:
                result.is_valid = False
                result.error_message = "Value must be one of: " + self._join_enum_values(param_def.enum_values)
                return result
        
        return result
    
    fn _is_number(self, value: String) -> Bool:
        """Check if a string represents a valid number."""
        if len(value) == 0:
            return False
        
        var has_dot = False
        var start_idx = 0
        
        # Check for negative sign
        if len(value) > 0 and String(value[0]) == "-":
            start_idx = 1
            if len(value) == 1:
                return False
        
        # Check each character
        for i in range(start_idx, len(value)):
            var char = String(value[i])
            if char == ".":
                if has_dot:
                    return False  # Multiple dots
                has_dot = True
            elif not (char >= "0" and char <= "9"):
                return False  # Non-digit character
        
        return True
    
    fn _join_enum_values(self, enum_values: List[String]) -> String:
        """Join enum values into a readable string."""
        var result = String()
        for i in range(len(enum_values)):
            if i > 0:
                result = result + ", "
            result = result + enum_values[i]
        return result

@value
struct ValidationResult(Movable):
    """Result of tool argument validation."""
    var is_valid: Bool
    var errors: List[String]
    var warnings: List[String]
    
    fn __init__(out self):
        self.is_valid = True
        self.errors = List[String]()
        self.warnings = List[String]()
    
    fn add_error(mut self, message: String):
        """Add a validation error."""
        self.errors.append(message)
        self.is_valid = False
    
    fn add_warning(mut self, message: String):
        """Add a validation warning."""
        self.warnings.append(message)
    
    fn get_error_summary(self) -> String:
        """Get a summary of all errors."""
        if len(self.errors) == 0:
            return ""
        
        var summary = String("Validation errors: ")
        for i in range(len(self.errors)):
            if i > 0:
                summary = summary + "; "
            summary = summary + self.errors[i]
        
        return summary

@value
struct ParameterValidationResult(Movable):
    """Result of single parameter validation."""
    var is_valid: Bool
    var error_message: String
    
    fn __init__(out self):
        self.is_valid = True
        self.error_message = ""

@value
struct MCPToolContent(Movable):
    """Content item in a tool result."""
    var type: String  # "text", "image", "resource"
    var data: String  # Text content, base64 data, or URI
    var mime_type: String  # MIME type for resources
    
    fn __init__(out self, type: String, data: String, mime_type: String = ""):
        self.type = type
        self.data = data
        self.mime_type = mime_type
    
    fn to_json(self) -> String:
        """Convert content to JSON format."""
        var json = String('{"type":"', self.type, '"')
        
        if self.type == "text":
            json = json + ',"text":"' + self.data + '"'
        elif self.type == "image":
            json = json + ',"data":"' + self.data + '"'
            if self.mime_type != "":
                json = json + ',"mimeType":"' + self.mime_type + '"'
        elif self.type == "resource":
            json = json + ',"resource":"' + self.data + '"'
            if self.mime_type != "":
                json = json + ',"mimeType":"' + self.mime_type + '"'
        
        json = json + "}"
        return json

@value 
struct MCPToolResult(Movable):
    """Result of a tool execution."""
    var content: List[MCPToolContent]
    var is_error: Bool
    var error_message: String
    
    fn __init__(out self, is_error: Bool = False, error_message: String = ""):
        self.content = List[MCPToolContent]()
        self.is_error = is_error
        self.error_message = error_message
    
    fn add_text_content(mut self, text: String):
        """Add text content to the result."""
        var content = MCPToolContent("text", text)
        self.content.append(content)
    
    fn add_resource_content(mut self, uri: String, mime_type: String = ""):
        """Add resource reference content to the result."""
        var content = MCPToolContent("resource", uri, mime_type)
        self.content.append(content)
    
    fn to_json(self) -> String:
        """Convert result to MCP JSON format."""
        if self.is_error:
            return String('{"isError":true,"content":[{"type":"text","text":"', self.error_message, '"}]}')
        
        var json = String('{"content":[')
        for i in range(len(self.content)):
            if i > 0:
                json = json + ","
            json = json + self.content[i].to_json()
        json = json + "]}"
        return json

# Tool execution function type
alias ToolExecutionFunc = fn(String) raises -> MCPToolResult

@value
struct MCPToolRegistry(Movable):
    """Registry for managing MCP tools."""
    var tools: Dict[String, MCPTool]
    var tool_executors: Dict[String, ToolExecutionFunc]
    var enabled: Bool
    var max_execution_time_ms: Int  # Maximum execution time in milliseconds
    var max_concurrent_executions: Int  # Maximum concurrent tool executions
    var current_executions: Int  # Current number of running executions
    var safety_checks_enabled: Bool
    
    fn __init__(out self):
        self.tools = Dict[String, MCPTool]()
        self.tool_executors = Dict[String, ToolExecutionFunc]()
        self.enabled = True
        self.max_execution_time_ms = 30000  # 30 seconds default
        self.max_concurrent_executions = 10  # Maximum 10 concurrent executions
        self.current_executions = 0
        self.safety_checks_enabled = True
    
    fn register_tool(mut self, tool: MCPTool, executor: ToolExecutionFunc) raises:
        """Register a new tool with its executor function."""
        if tool.name in self.tools:
            raise Error("Tool already registered: " + tool.name)
        
        self.tools[tool.name] = tool
        self.tool_executors[tool.name] = executor
        print("Tool registered: " + tool.name)
    
    fn unregister_tool(mut self, tool_name: String) raises:
        """Unregister a tool."""
        if tool_name not in self.tools:
            raise Error("Tool not found: " + tool_name)
        
        _ = self.tools.pop(tool_name)
        _ = self.tool_executors.pop(tool_name)
        print("Tool unregistered: " + tool_name)
    
    fn get_tool(self, tool_name: String) raises -> MCPTool:
        """Get a tool definition by name."""
        if tool_name not in self.tools:
            raise Error("Tool not found: " + tool_name)
        
        return self.tools[tool_name]
    
    fn list_tools(self) -> List[MCPTool]:
        """Get list of all registered tools."""
        var tool_list = List[MCPTool]()
        for tool_name in self.tools:
            try:
                var tool = self.tools[tool_name]
                if tool.enabled:
                    tool_list.append(tool)
            except:
                continue
        return tool_list
    
    fn execute_tool(mut self, tool_name: String, arguments_json: String) raises -> MCPToolResult:
        """Execute a tool with the provided arguments and safety checks."""
        if not self.enabled:
            var error_result = MCPToolResult(True, "Tool execution is disabled")
            return error_result
        
        if tool_name not in self.tools:
            var error_result = MCPToolResult(True, "Tool not found: " + tool_name)
            return error_result
        
        var tool = self.tools[tool_name]
        if not tool.enabled:
            var error_result = MCPToolResult(True, "Tool is disabled: " + tool_name)
            return error_result
        
        # Safety checks
        if self.safety_checks_enabled:
            if self.current_executions >= self.max_concurrent_executions:
                var error_result = MCPToolResult(True, "Maximum concurrent executions exceeded")
                return error_result
        
        # Validate arguments
        try:
            var validation = tool.validate_arguments(arguments_json)
            if not validation.is_valid:
                var error_result = MCPToolResult(True, validation.get_error_summary())
                return error_result
        except e:
            var error_result = MCPToolResult(True, "Argument validation failed")
            return error_result
        
        # Execute the tool with safety monitoring
        self.current_executions += 1
        try:
            var executor = self.tool_executors[tool_name]
            var result = self._execute_with_timeout(executor, arguments_json)
            self.current_executions -= 1
            return result
        except e:
            self.current_executions -= 1
            var error_result = MCPToolResult(True, "Tool execution failed")
            return error_result
    
    fn _execute_with_timeout(self, executor: ToolExecutionFunc, arguments_json: String) raises -> MCPToolResult:
        """Execute a tool function with timeout protection."""
        # TODO: Implement actual timeout mechanism
        # For now, just execute directly
        return executor(arguments_json)
    
    fn configure_safety(mut self, max_execution_time_ms: Int, max_concurrent_executions: Int):
        """Configure safety parameters."""
        self.max_execution_time_ms = max_execution_time_ms
        self.max_concurrent_executions = max_concurrent_executions
        print("Safety configuration updated: timeout=" + String(max_execution_time_ms) + 
              "ms, max_concurrent=" + String(max_concurrent_executions))
    
    fn enable_safety_checks(mut self):
        """Enable safety checks."""
        self.safety_checks_enabled = True
        print("Safety checks enabled")
    
    fn disable_safety_checks(mut self):
        """Disable safety checks (use with caution).""" 
        self.safety_checks_enabled = False
        print("Safety checks disabled - use with caution!")
    
    fn get_execution_stats(self) -> ExecutionStats:
        """Get current execution statistics."""
        return ExecutionStats(
            self.current_executions,
            self.max_concurrent_executions,
            self.max_execution_time_ms,
            self.safety_checks_enabled
        )
    
    fn enable_tool(mut self, tool_name: String) raises:
        """Enable a specific tool."""
        if tool_name not in self.tools:
            raise Error("Tool not found: " + tool_name)
        
        try:
            var tool = self.tools[tool_name]
            tool.enabled = True
            self.tools[tool_name] = tool
        except:
            raise Error("Failed to enable tool: " + tool_name)
    
    fn disable_tool(mut self, tool_name: String) raises:
        """Disable a specific tool."""
        if tool_name not in self.tools:
            raise Error("Tool not found: " + tool_name)
        
        try:
            var tool = self.tools[tool_name]
            tool.enabled = False
            self.tools[tool_name] = tool
        except:
            raise Error("Failed to disable tool: " + tool_name)
    
    fn enable_all_tools(mut self):
        """Enable all tools."""
        self.enabled = True
        for tool_name in self.tools:
            try:
                var tool = self.tools[tool_name]
                tool.enabled = True
                self.tools[tool_name] = tool
            except:
                print("Failed to enable tool: " + tool_name)
    
    fn disable_all_tools(mut self):
        """Disable all tools."""
        self.enabled = False
        for tool_name in self.tools:
            try:
                var tool = self.tools[tool_name]
                tool.enabled = False
                self.tools[tool_name] = tool
            except:
                print("Failed to disable tool: " + tool_name)
    
    fn get_tool_count(self) -> Int:
        """Get the number of registered tools."""
        return len(self.tools)
    
    fn get_enabled_tool_count(self) -> Int:
        """Get the number of enabled tools."""
        var count = 0
        for tool_name in self.tools:
            try:
                var tool = self.tools[tool_name]
                if tool.enabled:
                    count += 1
            except:
                continue
        return count

# Utility functions for creating common tool parameter types

fn create_string_parameter(name: String, description: String, required: Bool = True, 
                          default_value: String = "") -> MCPToolParameter:
    """Create a string parameter."""
    return MCPToolParameter(name, TOOL_TYPE_STRING, description, required, default_value)

fn create_number_parameter(name: String, description: String, required: Bool = True,
                          default_value: String = "") -> MCPToolParameter:
    """Create a number parameter."""
    return MCPToolParameter(name, TOOL_TYPE_NUMBER, description, required, default_value)

fn create_boolean_parameter(name: String, description: String, required: Bool = True,
                           default_value: String = "false") -> MCPToolParameter:
    """Create a boolean parameter.""" 
    return MCPToolParameter(name, TOOL_TYPE_BOOLEAN, description, required, default_value)

fn create_enum_parameter(name: String, description: String, enum_values: List[String],
                        required: Bool = True, default_value: String = "") -> MCPToolParameter:
    """Create an enum parameter."""
    return MCPToolParameter(name, TOOL_TYPE_STRING, description, required, default_value, enum_values)

@value
struct ExecutionStats(Movable):
    """Statistics about tool execution."""
    var current_executions: Int
    var max_concurrent_executions: Int
    var max_execution_time_ms: Int
    var safety_checks_enabled: Bool
    
    fn __init__(out self, current_executions: Int, max_concurrent_executions: Int,
                max_execution_time_ms: Int, safety_checks_enabled: Bool):
        self.current_executions = current_executions
        self.max_concurrent_executions = max_concurrent_executions
        self.max_execution_time_ms = max_execution_time_ms
        self.safety_checks_enabled = safety_checks_enabled
    
    fn to_json(self) -> String:
        """Convert statistics to JSON format."""
        return String('{"currentExecutions":', String(self.current_executions),
                     ',"maxConcurrentExecutions":', String(self.max_concurrent_executions),
                     ',"maxExecutionTimeMs":', String(self.max_execution_time_ms),
                     ',"safetyChecksEnabled":', String(self.safety_checks_enabled), '}')
    
    fn utilization_percent(self) -> Float64:
        """Get current utilization as percentage."""
        if self.max_concurrent_executions == 0:
            return 0.0
        return Float64(self.current_executions) / Float64(self.max_concurrent_executions) * 100.0