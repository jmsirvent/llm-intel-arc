### What is a Race Condition?

A **race condition** occurs in multi-threaded or multi-process programming when the outcome of a program depends on the unpredictable timing or sequence of events. 

It happens when two or more threads access and manipulate **shared data** at the same time. Because the operating system can switch between threads at any micro-moment (preemption), the threads might "interleave" their operations in a way that leads to corrupted data.

**The classic scenario:**
1. Thread A reads a value (e.g., `x = 10`).
2. The OS pauses Thread A and switches to Thread B.
3. Thread B reads the same value (`x = 10`).
4. Thread B increments it and saves it (`x = 11`).
5. The OS switches back to Thread A.
6. Thread A (still holding the old value of 10) increments it and saves it (`x = 11`).

**The result:** Even though two threads performed an increment, the value is `11` instead of `12`. One update was "lost."

---

### Python Example: The "Bank Account" Problem

In this example, we simulate a bank account where two threads try to deposit $1 simultaneously. Because the operation `balance += 1` is not "atomic" (it involves reading, adding, and writing), a race condition occurs.

```python
import threading
import time

# Shared resource
balance = 0

def deposit():
    global balance
    for _ in range(100000):
        # This line is the "Critical Section"
        # It looks like one step, but Python performs:
        # 1. Load balance
        # 2. Add 1
        # 3. Store balance
        balance += 1

# Create two threads that both try to increment the balance
thread1 = threading.Thread(target=deposit)
thread2 = threading.Thread(target=deposit)

# Start both threads
thread1.start()
thread2.start()

# Wait for both to finish
thread1.join()
thread2.join()

# Expected result: 200,000
# Actual result: Usually a much smaller, random number
print(f"Final Balance: {balance}")
```

### Why does this happen?
If you run this code, you will notice the final balance is almost never 200,000. It might be 142,304 or 167,000. 

This happens because:
1. **Thread 1** reads `balance` as `500`.
2. The OS switches to **Thread 2**.
3. **Thread 2** reads `balance` as `500`.
4. **Thread 2** adds 1 and saves `501`.
5. The OS switches back to **Thread 1**.
6. **Thread 1** (which already "remembered" 500) adds 1 and saves `501`.
7. **One deposit is lost.**

### How to fix it?
To prevent race conditions, you use a **Lock** (also known as a Mutex). A lock ensures that only one thread can enter the "Critical Section" at a time.

**The Fix:**
```python
import threading

balance = 0
lock = threading.Lock() # Create a lock object

def deposit():
    global balance
    for _
