A **race condition** occurs when the behavior of a program depends on the sequence or timing of events, such as the order in which threads execute. It typically happens when multiple threads access shared data and at least one of them modifies it, leading to unpredictable results due to the lack of proper synchronization.

### Key Characteristics of a Race Condition:
- Multiple threads access shared data.
- At least one thread modifies the data.
- The outcome depends on the order of thread execution.

---

### Minimal Python Example Demonstrating a Race Condition

Here's a simple example using Python's `threading` module that demonstrates a race condition:

```python
import threading

# Shared variable
counter = 0

def increment():
    global counter
    for _ in range(100000):
        counter += 1  # This line is not atomic and can cause a race condition

# Create two threads
thread1 = threading.Thread(target=increment)
thread2 = threading.Thread(target=increment)

# Start both threads
thread1.start()
thread2.start()

# Wait for both threads to complete
thread1.join()
thread2.join()

print("Final counter value:", counter)
```

---

### What's Happening Here?

- The `counter` variable is shared between two threads.
- Each thread increments the counter 100,000 times.
- The operation `counter += 1` is **not atomic** in Python. It involves:
  1. Reading the current value of `counter`.
  2. Adding 1 to it.
  3. Writing the new value back to `counter`.

If two threads read the same value of `counter` at the same time, they may both increment it to the same new value, and one of the increments will be lost.

---

### Expected vs. Actual Output

- **Expected**: `200000` (since each thread increments 100,000 times)
- **Actual**: Likely **less than 200,000** due to race conditions.

---

### How to Fix It

To avoid the race condition, you can use a **lock** (mutex) to ensure that only one thread can modify the shared variable at a time:

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

print("Final counter value:", counter)
```

Now the output will reliably be `200000`.

---

### Summary

- A **race condition** occurs when multiple threads access shared data and at least one modifies it.
- It leads to **unpredictable results**.
- Use **locks** or other synchronization mechanisms to prevent race conditions.
