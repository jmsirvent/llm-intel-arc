A race condition occurs when two or more threads or processes access and manipulate shared data concurrently, and the outcome depends on the timing of their execution. This can lead to unpredictable results and bugs because the threads may interfere with each other's operations, causing data corruption or inconsistent states.

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
print(f"Final counter value: {counter}")
```

In this example, we have a shared variable `counter` that is incremented by two threads. Since both threads are modifying the same variable without any synchronization mechanism (like locks), they can interfere with each other, leading to an incorrect final value of `counter`. The expected value should be 200000 (100000 + 100000), but due to the race condition, the actual result may be less than that. This is because the increments from both threads may overlap, causing some increments to be lost.
