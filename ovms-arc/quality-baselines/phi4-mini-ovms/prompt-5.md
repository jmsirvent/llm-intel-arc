A race condition occurs when two or more threads access shared data and try to change it at the same time. If the threads are not properly synchronized, the outcome can be unpredictable, leading to inconsistent or incorrect results.

Here's a minimal Python example that demonstrates a race condition using threading:

```python
import threading

# Shared variable
counter = 0

# Function to increment the counter
def increment():
    global counter
    for _ in range(100000):
        counter += 1

# Create two threads that will increment the counter
thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

# Start the threads
thread1.start()
thread2.start()

# Wait for both threads to finish
thread1.join()
thread2.join()

# Print the final value of the counter
print("Final counter value:", counter)
```

In this example, two threads are created that both increment the `counter` variable 100,000 times. Due to the race condition, the final value of `counter` may not be 200,000 as expected; it could be less than that because the threads may read and write the `counter` variable simultaneously, leading to lost updates. To avoid this, you would need to use synchronization mechanisms like locks.
