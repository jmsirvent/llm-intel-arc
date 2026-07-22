A race condition in programming occurs when two or more threads can access shared data and they try to change it at the same time. Because the thread scheduling algorithm can swap between threads at any time, you don't know the order in which the threads will attempt to access the shared data. As a result, you end up with inconsistent results.

Here's an example of a race condition in Python:

```python
import threading

counter = 0

def increment():
    global counter
    for _ in range(1000):
        counter += 1

threads = []
for i in range(10):
    t = threading.Thread(target=increment)
    threads.append(t)
    t.start()

for t in threads:
    t.join()

print(f"Final counter value: {counter}")
```

In this code, we have multiple threads incrementing a shared variable `counter`. Each thread runs the `increment` function, which increments `counter` 1000 times. The expected final value of `counter` should be 10000 (since there are 10 threads each incrementing `counter` 1000 times). However, due to the race condition, the actual final value might be less than 10000 because some increments might get lost due to the concurrent execution of threads.

To avoid race conditions, you can use synchronization mechanisms like locks to ensure that only one thread can modify the shared data at a time. Here's how you can modify the above code to use a lock:

```python
import threading

counter = 0
lock = threading.Lock()

def increment():
    global counter
    for _ in range(1000):
        with lock:
            counter += 1

threads = []
for i in range(10):
    t = threading.Thread(target=increment)
    threads.append(t)
    t.start()

for t in threads:
    t.join()

print(f"Final counter value: {counter}")
```

With the lock, only one thread can enter the critical section where `counter` is incremented, thus preventing race conditions.
