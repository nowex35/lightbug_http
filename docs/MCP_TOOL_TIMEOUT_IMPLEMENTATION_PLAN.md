# MCP Tool Timeout Implementation Plan

## Overview
This document outlines the implementation plan for adding true timeout cancellation to MCP tool execution. Currently, the system can only detect timeouts after execution completes. This plan will enable mid-execution cancellation of long-running tools.

## Current Implementation Status

### What's Already Implemented
1. **Request-level timeout tracking** (`timeout.mojo`)
   - `TimeoutManager` - Tracks JSON-RPC request timeouts
   - `PendingRequest` - Individual request timeout state
   - `TimeoutConfig` - Configurable timeout settings (default 30s, max 5min)
   - Progress notification support for timeout reset
   - Request cancellation tracking

2. **Tool execution time tracking** (`tools.mojo`)
   - `ToolExecutionInfo` - Tracks individual tool execution time
   - `MCPToolRegistry.active_executions` - Manages active executions
   - Default execution timeout: 30 seconds
   - Max concurrent executions: 10
   - Post-execution timeout checking with warning logs

3. **Server integration** (`server.mojo`)
   - `MCPServer.timeout_manager` integrated into request handling
   - Expired request detection in `handle_request()`
   - Cancelled request rejection
   - Timeout tracking lifecycle management

### Current Limitations
1. **No mid-execution cancellation**
   - Tools run to completion regardless of timeout
   - Timeout only detected after execution finishes
   - Long-running tools cannot be interrupted

2. **Fork-based execution not implemented**
   - Comment exists: "For true cancellation, use fork-based execution in server.mojo"
   - StreamingServer uses fork (streaming/server.mojo:129-160) but not for tool execution

3. **Client notification incomplete**
   - `CancellationNotification` struct exists but notifications aren't sent
   - Only logs timeout events locally

## Implementation Approach

### Option 1: Fork-Based Timeout Execution (Recommended)

Use the same fork pattern as StreamingServer to execute tools in child processes that can be killed on timeout.

#### Architecture

```
Parent Process                      Child Process
-------------                       -------------
fork() ──────────────────────────> Tool Execution
   │                                     │
   │                                     │
   ├─ Create pipe for IPC                │
   │                                     │
   ├─ Monitor timeout                    │
   │   └─ waitpid(WNOHANG)              │
   │       every 100ms                   │
   │                                     │
   ├─ If timeout:                        │
   │   └─ kill(SIGKILL) ────────────────> [Terminated]
   │                                     │
   ├─ Wait for result                    │
   │   via pipe/file <──────────────────┘
   │                           (write result)
   └─ Return result
      or timeout error
```

#### Key Components

1. **Modified `MCPToolRegistry._execute_with_timeout_fork()`**
   - Replace current `_execute_with_timeout_request()`
   - Fork child process for tool execution
   - Parent monitors timeout and kills if exceeded
   - Use pipe or shared file for result communication

2. **Inter-Process Communication (IPC)**
   - **Option A: Pipe** (faster, more complex)
     - Create pipe before fork
     - Child writes serialized result to pipe
     - Parent reads from pipe
   - **Option B: Temporary File** (simpler, slower)
     - Generate unique temp file path
     - Child writes result to file
     - Parent reads file after completion
     - Clean up file after reading

3. **Timeout Monitoring Loop**
   ```mojo
   var start_time = current_time_ms()
   while True:
       var status = waitpid(pid, WNOHANG)
       if status == pid:
           # Child completed
           break

       var elapsed = current_time_ms() - start_time
       if elapsed >= timeout_ms:
           # Timeout - kill child
           kill(pid, SIGKILL)
           waitpid(pid, 0)  # Reap zombie
           raise TimeoutError()

       sleep(100)  # Check every 100ms
   ```

4. **Result Serialization**
   - Serialize `MCPToolResult` to JSON
   - Write to pipe/file
   - Deserialize in parent process

5. **Zombie Process Cleanup**
   - Reuse existing `delete_zombies()` from process module
   - Call periodically in server main loop
   - Ensure proper `waitpid()` after kill

### Option 2: Signal-Based Timeout (Alternative)

Use `alarm()` or `setitimer()` to set a timeout signal.

#### Pros
- Lighter weight than fork
- Single process execution
- Less IPC overhead

#### Cons
- Requires signal handler implementation in Mojo
- Signal handling complexity
- May interfere with other signals
- Less clean separation

**Decision: Option 1 (Fork-Based) is recommended** due to proven usage in StreamingServer and cleaner isolation.

## Implementation Plan

### Phase 1: Core Fork-Based Execution
**Files to modify:**
- `lightbug_http/mcp/tools.mojo`
- `lightbug_http/_libc.mojo` (if additional syscalls needed)

**Tasks:**
1. Add IPC mechanism (choose pipe or file-based)
   - If pipe: Add `pipe()`, `read()`, `write()` syscalls to `_libc.mojo`
   - If file: Use existing file I/O

2. Implement `_execute_with_timeout_fork()`
   - Fork child process
   - Execute tool in child
   - Serialize and send result via IPC
   - Monitor timeout in parent
   - Kill on timeout with `SIGKILL`

3. Add result serialization/deserialization
   - JSON encoding of `MCPToolResult`
   - Error handling for serialization failures

4. Integrate into `execute_tool()`
   - Add configuration flag: `use_fork_timeout: Bool`
   - Fallback to old implementation if disabled
   - Handle fork failures gracefully

### Phase 2: Client Notification
**Files to modify:**
- `lightbug_http/mcp/server.mojo`
- `lightbug_http/mcp/streaming_transport.mojo`

**Tasks:**
1. Implement notification sending in `MCPServer`
   - Send `CancellationNotification` on timeout
   - Send via streaming transport

2. Add notification queue
   - Store notifications for async sending
   - Process queue during event loop

3. Update `handle_request()` to emit notifications
   - After detecting expired requests
   - After killing timed-out tool executions

### Phase 3: Configuration and Testing
**Files to modify:**
- `lightbug_http/mcp/timeout.mojo`
- Test files (to be created)

**Tasks:**
1. Add fork-based timeout configuration
   - `TimeoutConfig.use_fork_execution: Bool`
   - Per-tool timeout overrides
   - Configure fork vs. signal vs. polling strategy

2. Create comprehensive tests
   - Test fast-completing tools
   - Test long-running tools that timeout
   - Test cancellation notifications
   - Test zombie process cleanup
   - Test concurrent executions with timeouts

3. Performance benchmarking
   - Measure fork overhead
   - Compare with non-fork execution
   - Optimize IPC mechanism

### Phase 4: Documentation and Examples
**Files to create/modify:**
- This document
- `docs/MCP_COMPREHENSIVE_STATUS_REPORT.md`
- Example tools with configurable delays

**Tasks:**
1. Update status report with new capabilities
2. Add usage examples
3. Document configuration options
4. Add troubleshooting guide

## Technical Details

### IPC Mechanism Decision

#### Pipe-Based IPC (Recommended for Phase 1)
```mojo
# Parent creates pipe before fork
var pipe_fds = create_pipe()  # Returns [read_fd, write_fd]

var pid = fork()
if pid == 0:
    # Child: close read end, write result
    close(pipe_fds[0])
    var result_json = result.to_json()
    write(pipe_fds[1], result_json)
    close(pipe_fds[1])
    exit(0)
else:
    # Parent: close write end, read result
    close(pipe_fds[1])
    var result_json = read_all(pipe_fds[0])
    close(pipe_fds[0])
    var result = MCPToolResult.from_json(result_json)
```

**Required additions to `_libc.mojo`:**
```mojo
fn pipe(fildes: UnsafePointer[Int32]) -> Int32
fn close(fd: Int32) -> Int32
fn read(fd: Int32, buf: UnsafePointer[UInt8], count: Int) -> Int
fn write(fd: Int32, buf: UnsafePointer[UInt8], count: Int) -> Int
```

#### File-Based IPC (Fallback)
```mojo
# Use temporary file
var temp_path = "/tmp/mcp_tool_result_" + execution_id + ".json"

var pid = fork()
if pid == 0:
    # Child: write result to file
    var result_json = result.to_json()
    write_file(temp_path, result_json)
    exit(0)
else:
    # Parent: wait, then read file
    waitpid(pid, ...)
    if file_exists(temp_path):
        var result_json = read_file(temp_path)
        var result = MCPToolResult.from_json(result_json)
        remove_file(temp_path)
```

### Error Handling Strategy

1. **Fork failure**
   - Fall back to non-fork execution
   - Log warning
   - Continue with post-execution timeout check

2. **IPC failure**
   - Return error result
   - Clean up child process
   - Log detailed error

3. **Timeout occurred**
   - Kill child with `SIGKILL`
   - Return timeout error response
   - Send cancellation notification
   - Clean up IPC resources

4. **Serialization failure**
   - Return error result
   - Log serialization error
   - Clean up properly

### Performance Considerations

1. **Fork overhead**
   - ~1-2ms per fork on modern systems
   - Acceptable for typical tool execution times (>100ms)
   - Can be disabled for fast tools via config

2. **IPC overhead**
   - Pipe: minimal (~0.1ms)
   - File: higher (~1-5ms depending on I/O)
   - JSON serialization: depends on result size

3. **Monitoring frequency**
   - Check every 100ms by default
   - Configurable via `TimeoutConfig`
   - Balance between responsiveness and CPU usage

## Success Criteria

1. **Functional Requirements**
   - ✓ Tools can be killed mid-execution on timeout
   - ✓ Timeout errors returned to client
   - ✓ No zombie processes left behind
   - ✓ Cancellation notifications sent to clients
   - ✓ Concurrent tool executions handled correctly

2. **Performance Requirements**
   - ✓ Fork overhead < 5ms per execution
   - ✓ Timeout detection within 200ms of expiry
   - ✓ No memory leaks from IPC
   - ✓ Handle 100+ concurrent tool executions

3. **Reliability Requirements**
   - ✓ Graceful degradation on fork failure
   - ✓ Proper cleanup on all error paths
   - ✓ No resource leaks (file descriptors, processes)
   - ✓ Stable under stress testing

## Open Questions

1. **Should fork-based timeout be opt-in or opt-out?**
   - Proposal: Opt-in via configuration flag initially
   - Reason: Allow testing and validation before default

2. **Should we implement pipe-based IPC first or file-based?**
   - Proposal: Start with file-based for simplicity
   - Optimize to pipes in Phase 2 if needed

3. **How to handle tools that need to clean up resources?**
   - Proposal: Add optional cleanup callback
   - Call before exit in child process
   - Best-effort only (SIGKILL can't be caught)

4. **Should we support SIGTERM before SIGKILL?**
   - Proposal: Grace period approach
   - Send SIGTERM first, wait 1s, then SIGKILL
   - Allows tools to clean up if they handle signals

## Timeline Estimate

- **Phase 1**: 2-3 days (core implementation)
- **Phase 2**: 1-2 days (notifications)
- **Phase 3**: 2-3 days (testing and optimization)
- **Phase 4**: 1 day (documentation)

**Total**: ~6-9 days for complete implementation

## References

- Existing fork usage: `lightbug_http/streaming/server.mojo:129-160`
- Existing libc bindings: `lightbug_http/_libc.mojo`
- Existing timeout structures: `lightbug_http/mcp/timeout.mojo`
- Zombie cleanup: `lightbug_http/process.mojo`

## Next Steps

1. Review and approve this plan
2. Decide on IPC mechanism (pipe vs file)
3. Implement Phase 1 with feature flag
4. Test with sample long-running tool
5. Iterate and refine based on results
