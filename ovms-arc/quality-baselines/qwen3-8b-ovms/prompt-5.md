A **race condition** occurs in concurrent programming when two or more threads access a shared resource (like a variable or data structure) and at least one of them modifies it. Because the threads are executing simultaneously, the outcome depends on the **order** in which the threads execute, leading to **unpredictable or incorrect behavior**.

### Key Characteristics of a Race Condition:
- Multiple threads access a shared resource.
- At least one thread modifies the shared resource.
- The outcome depends on the timing of the threads.

---

### Minimal Python Example with a Race Condition Using Threading

```python
import threading

# Shared variable
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

### What Happens?

- Each thread is supposed to increment the `counter` 100,000 times.
- The expected final value is `200,000`.
- However, due to the **race condition**, the actual value may be **less than 200,000**.
- This happens because the `counter += 1` operation is not atomic. It involves:
  1. Reading the current value of `counter`.
  2. Adding 1 to it.
  3. Writing the new value back.

If two threads read the same value at the same time, they will both compute the same new value and write it back, leading to **lost updates**.

---

### How to Fix a Race Condition

To prevent race conditions, you can use **locks** (also called **mutexes**) to ensure that only one thread can access the shared resource at a time.

Here's the fixed version:

```python
import threading

# Shared variable
counter = 0
lock = threading.Lock()

def increment():
    global counter
    for _ in range(100000):
        with lock:
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

This ensures that the `counter += 1` operation is atomic, and the final value will be `200,000`.

---

### Summary

- A **race condition** occurs when multiple threads access shared data concurrently.
- It leads to **unpredictable behavior** due to the timing of thread execution.
- Use **locks** to synchronize access to shared resources and avoid race conditions.
