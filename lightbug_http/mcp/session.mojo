"""MCP Session Management System.

This module provides session management functionality for MCP servers,
including session ID generation, state management, and timeout handling.
"""

from collections import Dict
from python import Python
from random import random_si64

# Session states
alias SessionState = Int
alias SESSION_ACTIVE: SessionState = 0
alias SESSION_EXPIRED: SessionState = 1
alias SESSION_TERMINATED: SessionState = 2

fn current_time_ms() -> Int64:
    """Get current time in milliseconds using Python."""
    try:
        var time = Python.import_module("time")
        var current_time = time.time()
        return Int64(Float64(current_time) * 1000)
    except:
        # Fallback to a simple counter if Python fails
        return 1000000

@value
struct MCPSession(Movable):
    """Represents an MCP session with timeout management."""
    var session_id: String
    var connection_id: String
    var state: SessionState
    var created_at: Int64  # Unix timestamp in milliseconds
    var last_activity: Int64  # Unix timestamp in milliseconds
    var timeout_duration: Int64  # Session timeout in milliseconds (default: 30 minutes)
    var client_info: String  # JSON string with client information
    
    fn __init__(out self, session_id: String, connection_id: String, client_info: String = "{}"):
        self.session_id = session_id
        self.connection_id = connection_id
        self.state = SESSION_ACTIVE
        self.created_at = current_time_ms()
        self.last_activity = current_time_ms()
        self.timeout_duration = 30 * 60 * 1000  # 30 minutes in milliseconds
        self.client_info = client_info
    
    fn is_expired(self) -> Bool:
        """Check if the session has expired."""
        var current_time = current_time_ms()
        return (current_time - self.last_activity) > self.timeout_duration
    
    fn update_activity(mut self):
        """Update the last activity timestamp."""
        self.last_activity = current_time_ms()
    
    fn terminate(mut self):
        """Terminate the session."""
        self.state = SESSION_TERMINATED
    
    fn get_age_seconds(self) -> Int64:
        """Get session age in seconds."""
        return (current_time_ms() - self.created_at) / 1000
    
    fn get_inactive_seconds(self) -> Int64:
        """Get seconds since last activity."""
        return (current_time_ms() - self.last_activity) / 1000

@value
struct SessionManager(Movable):
    """Manages MCP sessions with automatic cleanup."""
    var sessions: Dict[String, MCPSession]
    var connection_to_session: Dict[String, String]  # Maps connection_id to session_id
    var cleanup_enabled: Bool
    var last_cleanup: Int64
    var cleanup_interval: Int64  # Cleanup interval in milliseconds (default: 5 minutes)
    
    fn __init__(out self):
        self.sessions = Dict[String, MCPSession]()
        self.connection_to_session = Dict[String, String]()
        self.cleanup_enabled = True
        self.last_cleanup = current_time_ms()
        self.cleanup_interval = 5 * 60 * 1000  # 5 minutes in milliseconds
    
    fn create_session(mut self, connection_id: String, client_info: String = "{}") -> String:
        """Create a new session and return the session ID."""
        var session_id = self._generate_session_id()
        var session = MCPSession(session_id, connection_id, client_info)
        
        self.sessions[session_id] = session
        self.connection_to_session[connection_id] = session_id
        
        print("Session created: " + session_id + " for connection: " + connection_id)
        return session_id
    
    fn get_session(self, session_id: String) raises -> MCPSession:
        """Get a session by ID."""
        if session_id not in self.sessions:
            raise Error("Session not found: " + session_id)
        return self.sessions[session_id]
    
    fn get_session_by_connection(self, connection_id: String) raises -> MCPSession:
        """Get a session by connection ID."""
        if connection_id not in self.connection_to_session:
            raise Error("No session found for connection: " + connection_id)
        
        var session_id = self.connection_to_session[connection_id]
        return self.get_session(session_id)
    
    fn update_session_activity(mut self, session_id: String) raises:
        """Update the last activity timestamp for a session."""
        if session_id not in self.sessions:
            raise Error("Session not found: " + session_id)
        
        var session = self.sessions[session_id]
        session.update_activity()
        self.sessions[session_id] = session
    
    fn terminate_session(mut self, session_id: String) raises:
        """Terminate a session."""
        if session_id not in self.sessions:
            return  # Session already doesn't exist
        
        var session = self.sessions[session_id]
        session.terminate()
        
        # Remove from both mappings
        _ = self.connection_to_session.pop(session.connection_id, "")
        _ = self.sessions.pop(session_id)
        
        print("Session terminated: " + session_id)
    
    fn terminate_session_by_connection(mut self, connection_id: String) raises:
        """Terminate a session by connection ID."""
        if connection_id in self.connection_to_session:
            try:
                var session_id = self.connection_to_session[connection_id]
                self.terminate_session(session_id)
            except:
                pass  # Session might have been already removed
    
    fn has_active_session(self, connection_id: String) -> Bool:
        """Check if a connection has an active session."""
        if connection_id not in self.connection_to_session:
            return False
        
        try:
            var session_id = self.connection_to_session[connection_id]
            if session_id not in self.sessions:
                return False
            
            var session = self.sessions[session_id]
            return session.state == SESSION_ACTIVE and not session.is_expired()
        except:
            return False
    
    fn cleanup_expired_sessions(mut self) -> Int:
        """Clean up expired sessions and return the number of sessions cleaned."""
        var current_time = current_time_ms()
        if not self.cleanup_enabled or (current_time - self.last_cleanup) < self.cleanup_interval:
            return 0
        
        # Collect expired session IDs
        var expired_sessions = List[String]()
        for session_id in self.sessions:
            try:
                var session = self.sessions[session_id]
                if session.is_expired() or session.state == SESSION_TERMINATED:
                    expired_sessions.append(session_id)
            except:
                # If we can't access the session, consider it for cleanup
                expired_sessions.append(session_id)
        
        # Remove expired sessions
        var cleaned_count = 0
        for i in range(len(expired_sessions)):
            try:
                self.terminate_session(expired_sessions[i])
                cleaned_count += 1
            except:
                pass  # Session might have been already removed
        
        self.last_cleanup = current_time
        
        if cleaned_count > 0:
            print("Cleaned up " + String(cleaned_count) + " expired sessions")
        
        return cleaned_count
    
    fn get_active_session_count(self) -> Int:
        """Get the number of active sessions."""
        var count = 0
        for session_id in self.sessions:
            try:
                var session = self.sessions[session_id]
                if session.state == SESSION_ACTIVE and not session.is_expired():
                    count += 1
            except:
                continue
        return count
    
    fn get_total_session_count(self) -> Int:
        """Get the total number of sessions (including expired)."""
        return len(self.sessions)
    
    fn set_cleanup_enabled(mut self, enabled: Bool):
        """Enable or disable automatic cleanup."""
        self.cleanup_enabled = enabled
    
    fn force_cleanup(mut self) -> Int:
        """Force immediate cleanup regardless of interval."""
        self.last_cleanup = 0  # Reset to force cleanup
        return self.cleanup_expired_sessions()
    
    fn _generate_session_id(self) -> String:
        """Generate a UUID v4 session ID."""
        # Generate random numbers for UUID v4
        var random1 = random_si64(-9223372036854775808, 9223372036854775807)
        var random2 = random_si64(-9223372036854775808, 9223372036854775807)
        
        # Convert to hex string - simplified UUID v4 format
        var result = String()
        
        # Generate 32 hex characters with dashes at appropriate positions
        for i in range(32):
            var digit = random_si64(0, 15)
            if digit < 10:
                result = result + String(digit)
            else:
                # Convert to hex a-f
                if digit == 10:
                    result = result + "a"
                elif digit == 11:
                    result = result + "b"
                elif digit == 12:
                    result = result + "c"
                elif digit == 13:
                    result = result + "d"
                elif digit == 14:
                    result = result + "e"
                else:
                    result = result + "f"
            
            # Add dashes at UUID positions: 8-4-4-4-12
            if i == 7 or i == 11 or i == 15 or i == 19:
                result = result + "-"
        
        return result

# Utility functions
fn create_session_manager() -> SessionManager:
    """Create a new session manager with default configuration."""
    return SessionManager()

fn extract_session_id_from_header(headers: String) -> String:
    """Extract session ID from Mcp-Session-Id header.
    
    Args:
        headers: HTTP headers as a string
    
    Returns:
        Session ID if found, empty string otherwise
    """
    # Simple header parsing - look for "Mcp-Session-Id: <value>"
    var lines = headers.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.lower().startswith("mcp-session-id:"):
            var parts = line.split(":", 1)
            if len(parts) >= 2:
                return String(parts[1].strip())
    
    return ""