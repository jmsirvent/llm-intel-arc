**What is a Race Condition?**

A race condition is a situation in which the behavior of a program depends on the relative timing or order of execution of multiple threads or processes. It occurs when two or more threads access shared resources simultaneously, and the outcome depends on the order in which they access these resources.

**Minimal Python Example**

Here's a simple example of a race condition using Python's threading module:

```python
import threading
import time

class Counter:
    def __init__(self):
        self.count = 0

    def increment(self):
        for _ in range(100000):
            self.count += 1

def worker(counter):
    counter.increment()

counter = Counter()

threads = []
for _ in range(10):
    thread = threading.Thread(target=worker, args=(counter,))
    thread.start()
    threads.append(thread)

for thread in threads:
    thread.join()

print(counter.count)
```

In this example, we have a `Counter` class with an `increment` method that increments a shared `count` attribute 100,000 times. We then create 10 threads that run the `worker` function, which increments the counter.

The problem with this code is that the `count` attribute is shared among all threads, and the order in which they increment it is not guaranteed. This can lead to a situation where the final count is not 1,000,000, but rather a lower value due to the threads interfering with each other.

**Why is this a race condition?**

This is a race condition because the outcome (the final count) depends on the relative timing of the threads. If one thread increments the count before another thread has a chance to, the final count will be lower than expected. If the threads increment the count in a specific order, the final count will be correct.

**How to fix a race condition?**

To fix a race condition, you need to ensure that shared resources are accessed in a thread-safe manner. One way to do this is by using locks, which prevent multiple threads from accessing a shared resource simultaneously.

Here's an updated version of the code that uses a lock to ensure thread safety:

```python
import threading
import time

class Counter:
    def __init__(self):
        self.count = 0
        self.lock = threading.Lock()

    def increment(self):
        for _ in range(100000):
            with self.lock:
                self.count += 1

def worker(counter):
    counter.increment()

counter = Counter()

threads = []
for _ in range(10):
    thread = threading.Thread(target=worker, args=(counter,))
    thread.start()
    threads.append(thread)

for thread in threads:
    thread.join()

print(counter.count)
```

In this updated code, we've added a `lock` attribute to the `Counter` class, which is a `threading.Lock` object. We've also modified the `increment` method to use the `with` statement to acquire the lock before incrementing the count, and release the lock afterwards.

By using a lock, we ensure that only one thread can increment the count at a time, preventing the race condition from occurring.
