"""Worker Pool System for Non-blocking Request Processing.

This module provides a worker pool system that allows the MCP server to process
requests concurrently without blocking the main event loop.
"""

from collections import Dict, List
from python import Python
from .async_io import AsyncEvent, current_timestamp_ms

# Worker states
alias WorkerState = Int
alias WORKER_IDLE: WorkerState = 0
alias WORKER_BUSY: WorkerState = 1
alias WORKER_STOPPING: WorkerState = 2
alias WORKER_STOPPED: WorkerState = 3

# Task types
alias TaskType = Int
alias TASK_HTTP_REQUEST: TaskType = 1
alias TASK_MCP_JSONRPC: TaskType = 2
alias TASK_TOOL_EXECUTION: TaskType = 3
alias TASK_SESSION_CLEANUP: TaskType = 4

# Task priorities
alias TaskPriority = Int
alias PRIORITY_LOW: TaskPriority = 0
alias PRIORITY_NORMAL: TaskPriority = 1
alias PRIORITY_HIGH: TaskPriority = 2
alias PRIORITY_CRITICAL: TaskPriority = 3

@value
struct WorkerTask(Movable):
    """Represents a task to be processed by a worker."""
    var task_id: String
    var task_type: TaskType
    var priority: TaskPriority
    var data: String
    var connection_id: String
    var session_id: String
    var created_at: Int64
    var timeout_ms: Int64
    var retry_count: Int
    var max_retries: Int
    
    fn __init__(out self, task_id: String, task_type: TaskType, data: String,
                connection_id: String = "", session_id: String = "",
                priority: TaskPriority = PRIORITY_NORMAL, timeout_ms: Int64 = 30000):
        self.task_id = task_id
        self.task_type = task_type
        self.priority = priority
        self.data = data
        self.connection_id = connection_id
        self.session_id = session_id
        self.created_at = current_timestamp_ms()
        self.timeout_ms = timeout_ms
        self.retry_count = 0
        self.max_retries = 3
    
    fn is_expired(self) -> Bool:
        """Check if this task has timed out."""
        return (current_timestamp_ms() - self.created_at) > self.timeout_ms
    
    fn can_retry(self) -> Bool:
        """Check if this task can be retried."""
        return self.retry_count < self.max_retries
    
    fn increment_retry(mut self):
        """Increment the retry counter."""
        self.retry_count += 1
    
    fn get_age_ms(self) -> Int64:
        """Get the age of this task in milliseconds."""
        return current_timestamp_ms() - self.created_at

@value
struct WorkerTaskResult(Movable):
    """Result of a worker task execution."""
    var task_id: String
    var success: Bool
    var result_data: String
    var error_message: String
    var execution_time_ms: Int64
    var worker_id: String
    
    fn __init__(out self, task_id: String, success: Bool = True, 
                result_data: String = "", error_message: String = "",
                execution_time_ms: Int64 = 0, worker_id: String = ""):
        self.task_id = task_id
        self.success = success
        self.result_data = result_data
        self.error_message = error_message
        self.execution_time_ms = execution_time_ms
        self.worker_id = worker_id

@value
struct Worker(Movable):
    """Represents a worker that can process tasks."""
    var worker_id: String
    var state: WorkerState
    var current_task: String  # Task ID being processed
    var tasks_processed: Int
    var total_execution_time_ms: Int64
    var last_activity: Int64
    var created_at: Int64
    var error_count: Int
    
    fn __init__(out self, worker_id: String):
        self.worker_id = worker_id
        self.state = WORKER_IDLE
        self.current_task = ""
        self.tasks_processed = 0
        self.total_execution_time_ms = 0
        self.last_activity = current_timestamp_ms()
        self.created_at = current_timestamp_ms()
        self.error_count = 0
    
    fn is_available(self) -> Bool:
        """Check if this worker is available to take on new tasks."""
        return self.state == WORKER_IDLE
    
    fn assign_task(mut self, task_id: String):
        """Assign a task to this worker."""
        self.current_task = task_id
        self.state = WORKER_BUSY
        self.last_activity = current_timestamp_ms()
    
    fn complete_task(mut self, execution_time_ms: Int64, success: Bool = True):
        """Mark a task as completed."""
        self.current_task = ""
        self.state = WORKER_IDLE
        self.tasks_processed += 1
        self.total_execution_time_ms += execution_time_ms
        self.last_activity = current_timestamp_ms()
        
        if not success:
            self.error_count += 1
    
    fn get_average_execution_time(self) -> Float64:
        """Get the average execution time for this worker."""
        if self.tasks_processed == 0:
            return 0.0
        return Float64(self.total_execution_time_ms) / Float64(self.tasks_processed)
    
    fn get_uptime_ms(self) -> Int64:
        """Get the uptime of this worker in milliseconds."""
        return current_timestamp_ms() - self.created_at

# Task processor function type
alias TaskProcessor = fn(WorkerTask) raises -> WorkerTaskResult

@value
struct WorkerPool(Movable):
    """Pool of workers for processing tasks concurrently."""
    var workers: Dict[String, Worker]
    var task_queue: List[WorkerTask]  # High priority queue
    var normal_queue: List[WorkerTask]  # Normal priority queue
    var low_queue: List[WorkerTask]   # Low priority queue
    var completed_tasks: Dict[String, WorkerTaskResult]
    var task_processors: Dict[TaskType, TaskProcessor]
    var is_running: Bool
    var max_workers: Int
    var max_queue_size: Int
    var worker_timeout_ms: Int64
    var completed_task_retention_ms: Int64
    var last_cleanup: Int64
    
    fn __init__(out self, max_workers: Int = 10, max_queue_size: Int = 1000):
        self.workers = Dict[String, Worker]()
        self.task_queue = List[WorkerTask]()
        self.normal_queue = List[WorkerTask]()
        self.low_queue = List[WorkerTask]()
        self.completed_tasks = Dict[String, WorkerTaskResult]()
        self.task_processors = Dict[TaskType, TaskProcessor]()
        self.is_running = False
        self.max_workers = max_workers
        self.max_queue_size = max_queue_size
        self.worker_timeout_ms = 300000  # 5 minutes
        self.completed_task_retention_ms = 60000  # 1 minute
        self.last_cleanup = current_timestamp_ms()
    
    fn start(mut self) raises:
        """Start the worker pool."""
        if self.is_running:
            raise Error("Worker pool is already running")
        
        # Create initial workers
        for i in range(self.max_workers):
            var worker_id = "worker_" + String(i)
            var worker = Worker(worker_id)
            self.workers[worker_id] = worker
        
        self.is_running = True
        print("Worker pool started with " + String(self.max_workers) + " workers")
    
    fn stop(mut self) raises:
        """Stop the worker pool and all workers."""
        if not self.is_running:
            return
        
        # Mark all workers as stopping
        for worker_id in self.workers:
            var worker = self.workers[worker_id]
            worker.state = WORKER_STOPPING
            self.workers[worker_id] = worker
        
        # Clear queues
        self.task_queue = List[WorkerTask]()
        self.normal_queue = List[WorkerTask]()
        self.low_queue = List[WorkerTask]()
        
        self.is_running = False
        print("Worker pool stopped")
    
    fn submit_task(mut self, task: WorkerTask) raises:
        """Submit a task to the worker pool."""
        if not self.is_running:
            raise Error("Worker pool is not running")
        
        var total_queued = len(self.task_queue) + len(self.normal_queue) + len(self.low_queue)
        if total_queued >= self.max_queue_size:
            raise Error("Task queue is full")
        
        # Add to appropriate priority queue
        if task.priority >= PRIORITY_HIGH:
            self.task_queue.append(task)
        elif task.priority == PRIORITY_NORMAL:
            self.normal_queue.append(task)
        else:
            self.low_queue.append(task)
        
        print("Task submitted: " + task.task_id + " (priority: " + String(task.priority) + ")")
    
    fn process_tasks(mut self) raises -> Int:
        """Process pending tasks. Returns number of tasks processed."""
        if not self.is_running:
            return 0
        
        var tasks_processed = 0
        
        # Find available workers and assign tasks
        for worker_id in self.workers:
            var worker = self.workers[worker_id]
            if worker.is_available():
                # Get next task from priority queues
                var next_task = self._get_next_task()
                if next_task.task_id != "":
                    try:
                        var result = self._process_task(worker_id, next_task)
                        self.completed_tasks[result.task_id] = result
                        tasks_processed += 1
                    except e:
                        print("Task processing error: " + String(e))
                        # Create error result
                        var error_result = WorkerTaskResult(
                            next_task.task_id, False, "", String(e), 0, worker_id
                        )
                        self.completed_tasks[next_task.task_id] = error_result
        
        # Cleanup expired completed tasks
        self._cleanup_completed_tasks()
        
        return tasks_processed
    
    fn register_processor(mut self, task_type: TaskType, processor: TaskProcessor):
        """Register a task processor for a specific task type."""
        self.task_processors[task_type] = processor
        print("Task processor registered for type: " + String(task_type))
    
    fn get_task_result(self, task_id: String) raises -> WorkerTaskResult:
        """Get the result of a completed task."""
        if task_id not in self.completed_tasks:
            raise Error("Task result not found: " + task_id)
        return self.completed_tasks[task_id]
    
    fn has_task_result(self, task_id: String) -> Bool:
        """Check if a task result is available."""
        return task_id in self.completed_tasks
    
    fn get_pool_stats(self) raises -> WorkerPoolStats:
        """Get current worker pool statistics."""
        var idle_workers = 0
        var busy_workers = 0
        
        for worker_id in self.workers:
            var worker = self.workers[worker_id]
            if worker.state == WORKER_IDLE:
                idle_workers += 1
            elif worker.state == WORKER_BUSY:
                busy_workers += 1
        
        var total_queued = len(self.task_queue) + len(self.normal_queue) + len(self.low_queue)
        
        return WorkerPoolStats(
            len(self.workers),
            idle_workers,
            busy_workers,
            total_queued,
            len(self.completed_tasks),
            self.is_running
        )
    
    fn _get_next_task(mut self) -> WorkerTask:
        """Get the next task from priority queues."""
        # High priority first
        if len(self.task_queue) > 0:
            var task = self.task_queue[0]
            _ = self.task_queue.pop(0)
            return task
        
        # Normal priority
        if len(self.normal_queue) > 0:
            var task = self.normal_queue[0]
            _ = self.normal_queue.pop(0)
            return task
        
        # Low priority
        if len(self.low_queue) > 0:
            var task = self.low_queue[0]
            _ = self.low_queue.pop(0)
            return task
        
        # No tasks available
        return WorkerTask("", TASK_HTTP_REQUEST, "")
    
    fn _process_task(mut self, worker_id: String, task: WorkerTask) raises -> WorkerTaskResult:
        """Process a task using the specified worker."""
        var worker = self.workers[worker_id]
        worker.assign_task(task.task_id)
        self.workers[worker_id] = worker
        
        var start_time = current_timestamp_ms()
        
        try:
            # Check if we have a processor for this task type
            if task.task_type in self.task_processors:
                var processor = self.task_processors[task.task_type]
                var result = processor(task)
                
                var execution_time = current_timestamp_ms() - start_time
                result.execution_time_ms = execution_time
                result.worker_id = worker_id
                
                # Update worker
                worker = self.workers[worker_id]
                worker.complete_task(execution_time, result.success)
                self.workers[worker_id] = worker
                
                return result
            else:
                # No processor registered for this task type
                var error_result = WorkerTaskResult(
                    task.task_id, False, "", 
                    "No processor registered for task type: " + String(task.task_type),
                    current_timestamp_ms() - start_time, worker_id
                )
                
                worker = self.workers[worker_id]
                worker.complete_task(current_timestamp_ms() - start_time, False)
                self.workers[worker_id] = worker
                
                return error_result
                
        except e:
            # Task processing failed
            var execution_time = current_timestamp_ms() - start_time
            var error_result = WorkerTaskResult(
                task.task_id, False, "", String(e), execution_time, worker_id
            )
            
            worker = self.workers[worker_id]
            worker.complete_task(execution_time, False)
            self.workers[worker_id] = worker
            
            return error_result
    
    fn _cleanup_completed_tasks(mut self) raises:
        """Clean up old completed task results."""
        var current_time = current_timestamp_ms()
        if (current_time - self.last_cleanup) < 30000:  # Cleanup every 30 seconds
            return
        
        var tasks_to_remove = List[String]()
        for task_id in self.completed_tasks:
            var result = self.completed_tasks[task_id]
            # Remove tasks older than retention period
            if (current_time - result.execution_time_ms) > self.completed_task_retention_ms:
                tasks_to_remove.append(task_id)
        
        var removed_count = 0
        for i in range(len(tasks_to_remove)):
            try:
                _ = self.completed_tasks.pop(tasks_to_remove[i])
                removed_count += 1
            except:
                pass
        
        self.last_cleanup = current_time
        
        if removed_count > 0:
            print("Cleaned up " + String(removed_count) + " completed task results")

@value
struct WorkerPoolStats(Movable):
    """Statistics for the worker pool."""
    var total_workers: Int
    var idle_workers: Int
    var busy_workers: Int
    var queued_tasks: Int
    var completed_tasks: Int
    var is_running: Bool
    
    fn __init__(out self, total_workers: Int, idle_workers: Int, busy_workers: Int,
                queued_tasks: Int, completed_tasks: Int, is_running: Bool):
        self.total_workers = total_workers
        self.idle_workers = idle_workers
        self.busy_workers = busy_workers
        self.queued_tasks = queued_tasks
        self.completed_tasks = completed_tasks
        self.is_running = is_running
    
    fn to_string(self) -> String:
        """Convert stats to a readable string."""
        var stats = String("Worker Pool Stats:\n")
        stats = stats + String("  Running: ") + String(self.is_running) + String("\n")
        stats = stats + String("  Workers: ") + String(self.total_workers) + String(" (idle: ") + String(self.idle_workers) + String(", busy: ") + String(self.busy_workers) + String(")\n")
        stats = stats + String("  Queued tasks: ") + String(self.queued_tasks) + String("\n")
        stats = stats + String("  Completed tasks: ") + String(self.completed_tasks)
        return stats
    
    fn utilization_percent(self) -> Float64:
        """Get worker utilization as percentage."""
        if self.total_workers == 0:
            return 0.0
        return Float64(self.busy_workers) / Float64(self.total_workers) * 100.0

# Utility functions
fn create_worker_pool(max_workers: Int = 10, max_queue_size: Int = 1000) -> WorkerPool:
    """Create a new worker pool with default configuration."""
    return WorkerPool(max_workers, max_queue_size)

fn generate_task_id() -> String:
    """Generate a unique task ID."""
    return "task_" + String(current_timestamp_ms())

# Default task processors
fn default_http_processor(task: WorkerTask) raises -> WorkerTaskResult:
    """Default processor for HTTP request tasks."""
    # Simulate HTTP request processing
    var result = WorkerTaskResult(task.task_id, True, "HTTP request processed", "")
    return result

fn default_jsonrpc_processor(task: WorkerTask) raises -> WorkerTaskResult:
    """Default processor for JSON-RPC tasks."""
    # Simulate JSON-RPC processing
    var result = WorkerTaskResult(task.task_id, True, "JSON-RPC request processed", "")
    return result

fn default_tool_processor(task: WorkerTask) raises -> WorkerTaskResult:
    """Default processor for tool execution tasks."""
    # Simulate tool execution
    var result = WorkerTaskResult(task.task_id, True, "Tool executed successfully", "")
    return result

fn default_cleanup_processor(task: WorkerTask) raises -> WorkerTaskResult:
    """Default processor for cleanup tasks."""
    # Simulate cleanup operations
    var result = WorkerTaskResult(task.task_id, True, "Cleanup completed", "")
    return result