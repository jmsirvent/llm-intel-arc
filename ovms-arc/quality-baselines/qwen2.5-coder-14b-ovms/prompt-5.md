A race condition occurs in concurrent programming when two or more threads access shared data and try to change it at the same time. This can lead to inconsistent or unexpected results because the final outcome depends on the sequence or timing of the thread execution.

Here's a minimal Python example demonstrating a race condition using the `threading` module:

```python
import threading

# Shared variable
counter = 0

def increment():
    global counter
    for _ in range(100000):
        # Critical section: accessing and modifying shared data
        counter += 1

# Create threads
thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

# Start threads
thread1.start()
thread2.start()

# Wait for threads to complete
thread1.join()
thread2.join()

print(f"Final counter value: {counter}")
```

In this example, two threads (`thread1` and `thread2`) both increment the `counter` variable 100,000 times. If the threads execute perfectly in an alternating fashion, the final value of `counter` would be 200,000. However, due to the nature of race conditions, the actual output might be less than 200,000 if the threads interfere with each other while updating the shared `counter` variable. This happens because the increment operation (`counter += 1`) is not atomic; it involves reading the current value, adding one, and then writing it back, which can be interrupted by another thread.
