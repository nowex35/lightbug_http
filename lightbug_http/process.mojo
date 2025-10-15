from lightbug_http._libc import wait4, WNOHANG, pid_t
from lightbug_http._logger import logger


fn delete_zombies() -> None:
    """Delete zombie processes by reaping terminated child processes.

    This function uses wait4() with the WNOHANG flag to non-blockingly reap
    any terminated child processes, preventing them from becoming zombies.
    It continues calling wait4() until no more terminated children exist.

    This should be called periodically in the main server loop to clean up
    child processes that have finished handling client connections.

    Reference: https://www.coins.tsukuba.ac.jp/~syspro/2024/2024-07-17/index.html
    """
    while True:
        try:
            # Wait for any child process (-1) with WNOHANG (non-blocking)
            # Returns:
            #   > 0: PID of reaped child process
            #   = 0: No terminated child processes available
            #   < 0: Error (handled by wait4 function)
            var pid = wait4(-1, WNOHANG)

            if pid == 0:
                # No more terminated child processes
                break
            elif pid > 0:
                logger.debug("Reaped zombie child process with PID:", String(pid))
            else:
                # Unexpected negative value (should not happen with our wait4 implementation)
                break
        except e:
            # ECHILD error (no child processes) is normal and expected
            if "ECHILD" in String(e) or "No child processes" in String(e):
                break
            else:
                logger.error("delete_zombies error:", String(e))
                break
