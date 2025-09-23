"""Model Context Protocol (MCP) implementation for Lightbug HTTP.

This module provides a complete MCP server implementation based on the 2025-06-18 specification,
including synchronous and asynchronous processing capabilities.
"""

# Core MCP components
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, JSONRPCError
from .server import MCPServer
from .transport import HTTPTransport, create_localhost_transport
from .stdio_transport import STDIOTransport, create_stdio_transport, create_debug_stdio_transport
from .messages import MCPMessage
from .session import SessionManager, MCPSession, create_session_manager

# Tools system
from .tools import MCPTool, MCPToolResult, MCPToolRegistry, MCPToolParameter
from .tools import create_string_parameter, create_number_parameter, create_boolean_parameter, create_enum_parameter

# Utility functions
from .utils import generate_uuid, generate_connection_id, generate_session_id, current_time_ms