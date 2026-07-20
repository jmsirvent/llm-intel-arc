## What is a Race Condition?

A **race condition** occurs when the behavior of a program depends on the **uncontrollable or unpredictable timing** of multiple threads (or processes) executing concurrently. Specifically, it happens when two or more threads access and modify the same shared resource (like a variable) simultaneously, and the final result depends on which thread runs first, second, or interleaved in some other order.

In simple terms: if the outcome changes based on who "wins the race" to read/write a variable, you have a race condition.

---

## Minimal Python Example

```python
import threading

counter = 0

def increment():
    global counter
    for _ in range(100_000):
        counter += 1  # Read-modify-write is not atomic!

threads = [threading.Thread(target=increment) for _ in range(10)]
for t in threads:
    t.start()
for t in threads:
    t.join()

print(f"Expected: 1,000,000 | Got: {counter}")
```

### Why this fails

The operation `counter += 1` looks simple, but under the hood it is **three steps**:

1. **Read** the current value of `counter`
2. **Add** 1 to it
3. **Write** the result back

If Thread A reads `counter = 5`, then Thread B also reads `counter = 5`, and both write back `6`, you've lost one increment. With 10 threads each doing 100,000 increments, the final value will almost always be **less than 1,000,000**.

### The fix (for reference)

Use a lock to make the operation atomic:

```python
import threading

counter = 0
lock = threading.Lock()

def increment():
    global counter
    for _ in range(100_000):
        with lock:
            counter += 1
```
