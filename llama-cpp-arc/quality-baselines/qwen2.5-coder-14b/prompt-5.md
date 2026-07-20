A race condition is a situation that can occur in concurrent programming when two or more threads access shared data and try to change it at the same time. The outcome depends on the sequence or timing of the thread execution, leading to unpredictable results. Race conditions can cause bugs that are difficult to reproduce and debug.

Here's a minimal Python example that demonstrates a race condition using the `threading` module:

```python
import threading

# Shared resource
counter = 0

# Function to increment the counter
def increment():
    global counter
    for _ in range(100000):
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

# Print the final value of the counter
print("Final counter value:", counter)
```

In this example, two threads (`thread1` and `thread2`) are created, each of which increments a shared `counter` variable 100,000 times. The expected final value of the counter should be 200,000, but due to the race condition, the actual value printed may be less than 200,000. This is because the increment operation (`counter += 1`) is not atomic; it involves reading the current value, adding one, and then writing the new value back. If both threads read the same value before either has written its incremented value, the final result will be incorrect.
