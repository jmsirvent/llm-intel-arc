## What is a Race Condition?

A **race condition** is a situation in concurrent programming where the final outcome of a program depends on the unpredictable order or timing in which multiple threads or processes access and modify shared data.

In essence, a race condition occurs when:

1. **Multiple threads** are trying to read and write to the **same shared resource** (like a variable, a file, or a database record) simultaneously.
2. The operations are **not atomic** (meaning they can be interrupted mid-operation).
3. The final state of the shared resource becomes **incorrect or unpredictable** because the interleaving of operations leads to a wrong result.

**Analogy:** Imagine two people trying to update a shared bank account balance at the exact same time. If both read the initial balance, calculate their new balance, and then write their result back, one update might overwrite the other, leading to an incorrect final balance.

### Key Characteristics:

* **Concurrency:** Requires multiple threads running at the same time.
* **Shared State:** Involves data accessible by more than one thread.
* **Non-Deterministic:** The error only appears sometimes, making it very hard to reproduce and debug.

---

## Minimal Python Example Demonstrating a Race Condition

This example uses Python's `threading` module to simulate two threads trying to increment a shared counter variable.

### The Problematic Code

```python
import threading
import time

# Shared resource
counter = 0

def increment_counter(num_increments):
    """
    This function is executed by multiple threads.
    It reads the current value, increments it, and writes it back.
    """
    global counter
    for _ in range(num_increments):
        # 1. Read the current value of counter
        current_value = counter
        
        # 2. Simulate a small delay (this is where the context switch happens)
        # The thread might be paused here by the OS scheduler.
        time.sleep(0.0001) 
        
        # 3. Calculate the new value
        new_value = current_value + 1
        
        # 4. Write the new value back
        counter = new_value

# --- Execution ---

NUM_THREADS = 5
INCREMENTS_PER_THREAD = 100000
EXPECTED_TOTAL = NUM_THREADS * INCREMENTS_PER_THREAD

threads = []

# Create and start the threads
for i in range(NUM_THREADS):
    thread = threading.Thread(target=increment_counter, args=(INCREMENTS_PER_THREAD,))
    threads.append(thread)
    thread.start()

# Wait for all threads to complete
for thread in threads:
    thread.join()

print(f"Expected final counter value: {EXPECTED_TOTAL}")
print(f"Actual final counter value: {counter}")

if counter != EXPECTED_TOTAL:
    print("\n*** RACE CONDITION DETECTED! The result is incorrect. ***")
else:
    print("\n(This run might have succeeded by chance, but the underlying mechanism is flawed.)")
```

### Explanation of the Race Condition in the Example

1. **Shared Resource:** The global variable `counter` is the shared resource.
2. **Non-Atomic Operation:** The operation `counter = counter + 1` is *not* atomic. It actually involves three separate steps:
    * **Read:** Read the current value of `counter` into a local variable (`current_value`).
    * **Modify:** Calculate the new value (`current_value + 1`).
    * **Write:** Assign the new value back to `counter`.
3. **The Interleaving:**
    * Thread A reads `counter` (e.g., value is 100).
    * The operating system pauses Thread A (context switch).
    * Thread B reads `counter` (it still sees 100).
    * Thread B calculates $100 + 1 = 101$ and writes `counter = 101`.
    * The OS switches back to Thread A.
    * Thread A resumes. It still holds the old value (100). It calculates $100 + 1 = 101$ and writes `counter = 101`.

In this scenario, two increments occurred, but the counter only increased by one. This loss of updates is the manifestation of the race condition.

### How to Fix It (Briefly)

To fix race conditions, you must ensure that the read-modify-write sequence is **atomic** (indivisible). In Python threading, this is typically achieved using **locks**:

```
