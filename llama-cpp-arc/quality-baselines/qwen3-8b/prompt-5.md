A **race condition** occurs in concurrent programming when two or more threads access shared data and at least one of the threads is modifying the data. Because the threads are executing concurrently, the final result depends on the order in which the threads are scheduled, leading to unpredictable and incorrect behavior.

### Key Characteristics of a Race Condition:
- **Shared data** is accessed by multiple threads.
- **Unsynchronized access** leads to inconsistent or incorrect results.
- The outcome depends on the **timing** of thread execution.

---

### Minimal Python Example Demonstrating a Race Condition Using Threading

```python
import threading

# Shared resource
counter = 0

def increment():
    global counter
    for _ in range(100000):
        counter += 1

# Create two threads
t1 = threading.Thread(target=increment)
t2 = threading.Thread(target=increment)

# Start the threads
t1.start()
t2.start()

# Wait for both threads to finish
t1.join()
t2.join()

print("Final counter value:", counter)
```

---

### What Happens in This Example?

- Each thread is supposed to increment the `counter` 100,000 times.
- The expected final value of `counter` should be `200,000`.
- However, due to the **race condition**, the actual value may be **less than 200,000**.

### Why?

- The `counter += 1` operation is **not atomic**.
- It involves:
  1. Reading the current value of `counter`.
  2. Incrementing it.
  3. Writing the new value back.
- If two threads read the same value at the same time, they will both increment the same number and write it back, leading to **lost updates**.

---

### Fixing the Race Condition

To fix this, you can use a **lock** (e.g., `threading.Lock`) to ensure that only one thread can modify the shared resource at a time:

```python
import threading

counter = 0
lock = threading.Lock()

def increment():
    global counter
    for _ in range(100000):
        with lock:
            counter += 1

t1 = threading.Thread(target=increment)
t2 = threading.Thread(target=increment)

t1.start()
t2.start()

t1.join()
t2.join()

print("Final counter value:", counter)
```

This ensures that the `counter` is updated safely and the race condition is avoided.
