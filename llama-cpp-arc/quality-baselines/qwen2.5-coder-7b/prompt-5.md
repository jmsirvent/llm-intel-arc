A race condition is a situation in which two or more threads or processes access shared data and they try to change it at the same time. Because the thread scheduling algorithm can swap between threads at any time, you don't know the order in which the threads will attempt to access the shared data. As a result, the final value of the shared data is unpredictable and depends on the timing of the threads' execution.

Here is a minimal Python example that demonstrates a race condition using threading:

```python
import threading

# Shared variable
counter = 0

# Function to increment the counter
def increment():
    global counter
    for _ in range(100000):
        counter += 1

# Create two threads
thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

# Start the threads
thread1.start()
thread2.start()

# Wait for the threads to complete
thread1.join()
thread2.join()

# Print the final value of the counter
print("Final counter value:", counter)
```

In this example, two threads are created that each increment a shared counter variable 100,000 times. The expected final value of the counter should be 200,000. However, due to the race condition, the actual final value may be less than 200,000 because the threads are accessing and modifying the shared variable concurrently.
