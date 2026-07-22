A **race condition** occurs when the behavior of a program depends on the sequence or timing of events, such as the order in which threads are scheduled. It typically happens when multiple threads access shared data and at least one of them modifies it, leading to unpredictable or incorrect results due to the interleaving of operations.

### Key Characteristics of a Race Condition:
- Multiple threads access shared data.
- At least one thread modifies the data.
- The outcome depends on the order of execution (i.e., scheduling of threads).

---

### Minimal Python Example Demonstrating a Race Condition

Here's a simple example using Python's `threading` module. We'll simulate a race condition by having two threads increment a shared counter.

```python
import threading

# Shared resource
counter = 0

def increment():
    global counter
    for _ in range(100000):
        counter += 1  # This line is not atomic and can be interrupted

# Create two threads
thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

# Start the threads
thread1.start()
thread2.start()

# Wait for both threads to complete
thread1.join()
thread2.join()

print(f"Final counter value: {counter}")
```

---

### What's Happening Here?

- The `counter` is a shared global variable.
- Each thread runs the `increment` function, which adds 100,000 to the counter.
- The operation `counter += 1` is **not atomic** — it involves reading the value, adding 1, and writing it back.
- If two threads are executing this at the same time, they might read the same value, increment it, and write it back, **overwriting each other's changes**.

### Expected vs. Actual Output

- **Expected**: `200000` (100,000 increments × 2 threads)
- **Actual**: Likely **less than 200000**, due to race conditions.

---

### How to Fix It

To avoid race conditions, you need to **synchronize access** to shared resources. In Python, you can use a `Lock`:

```python
import threading

counter = 0
lock = threading.Lock()

def increment():
    global counter
    for _ in range(100000):
        with lock:
            counter += 1

thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

thread1.start()
thread2.start()

thread1.join()
thread2.join()

print(f"Final counter value: {counter}")
```

Now the output will reliably be `200000`.

---

### Summary

- **Race condition**: Unpredictable behavior due to concurrent access to shared data.
- **Example**: Multiple threads incrementing a shared counter.
- **Fix**: Use synchronization primitives like `Lock` to ensure atomic access to shared resources.
