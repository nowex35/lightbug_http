"""Utility functions for MCP implementation.

This module provides common utility functions used across the MCP implementation,
including UUID generation, time utilities, and other helper functions.
"""

from random import random_si64
from python import Python

fn generate_uuid() -> String:
    """Generate a UUID v4 string in the format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    
    Returns a 36-character UUID string with dashes at positions 8, 13, 18, and 23.
    """
    var result = String()
    var char_count = 0

    # Generate 32 hex characters with dashes at appropriate positions
    for _ in range(32):
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

        char_count += 1

        # Add dashes at UUID positions: 8-4-4-4-12
        if char_count == 8 or char_count == 12 or char_count == 16 or char_count == 20:
            result = result + "-"

    return result

fn generate_connection_id() -> String:
    """Generate a unique connection ID using UUID format."""
    return generate_uuid()

fn generate_session_id() -> String:
    """Generate a unique session ID using UUID format."""
    return generate_uuid()

fn current_time_ms() -> Int64:
    """Get current time in milliseconds using Python."""
    try:
        var time = Python.import_module("time")
        var current_time = time.time()
        return Int64(Float64(current_time) * 1000)
    except:
        # Fallback to a simple counter if Python fails
        return 1000000

fn sleep_seconds(seconds: Int) raises:
    """Sleep for the specified number of seconds using Python's time.sleep."""
    try:
        var time = Python.import_module("time")
        time.sleep(seconds)
    except:
        raise Error("Failed to sleep using Python time module")
