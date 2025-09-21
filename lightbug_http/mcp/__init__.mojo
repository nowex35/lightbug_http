"""Model Context Protocol (MCP) implementation for Lightbug HTTP.

This module provides a complete MCP server implementation based on the 2025-06-18 specification,
including synchronous and asynchronous processing capabilities.
"""

# Core MCP components
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, JSONRPCError
from .server import MCPServer, create_mcp_server
from .transport import HTTPTransport, create_localhost_transport
from .messages import MCPMessage
from .session import SessionManager, MCPSession, create_session_manager

# Tools system
from .tools import MCPTool, MCPToolResult, MCPToolRegistry, MCPToolParameter, MCPToolAnnotation
from .tools import create_string_parameter, create_number_parameter, create_boolean_parameter, create_enum_parameter

# Async I/O and concurrent processing (Phase 3 - Experimental)
# Note: These are experimental features for future development
# from .async_io import AsyncEventLoop, AsyncEvent, AsyncConnection, create_async_event_loop
# from .async_http_server import AsyncMCPServer, create_production_async_server
# from .worker_pool import WorkerPool, WorkerTask, WorkerTaskResult, create_worker_pool
