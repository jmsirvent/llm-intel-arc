## What is a Race Condition?

A **race condition** is a situation in concurrent programming (when multiple threads or processes are running at the same time) where the outcome of the program depends on the unpredictable order in which the threads access and modify shared data.

Imagine two people trying to update the same bank account balance simultaneously. If both people read the initial balance, calculate their new balance, and then write it back, the final balance might be incorrect because one person's update overwrites the other's, even if both calculations were correct based on the initial state.

**In technical terms:**

1. **Shared Resource:** There is a piece of data (like a variable, file, or database record) that multiple threads can access.
2. **Non-Atomic Operation:** The operation on that shared resource (e.g., `count = count + 1`) is not *atomic*. This means it doesn't happen in a single, uninterruptible step. It usually involves three steps:
    * **Read:** Read the current value of the variable into a register.
    * **Modify:** Perform the calculation (e.g., add 1).
    * **Write:** Write the new value back to the variable.
3. **Interleaving:** If the operating system switches context (pauses one thread and starts another) *between* these three steps, the threads "race" to complete their operations, leading to an incorrect final state.

**The result is non-deterministic behavior:** Running the program twice might yield different, incorrect results.

---

## Minimal Python Example Demonstrating a Race Condition

We will use Python's `threading` module to demonstrate this. We will have multiple threads trying to increment a single shared counter variable.

### The Code

```python
import threading
import time

# 1. The Shared Resource
counter = 0
NUM_INCREMENTS = 100000

def increment_counter():
    """
    Function executed by each thread. It increments the global counter.
    """
    global counter
    for _ in range(NUM_INCREMENTS):
        # This operation (read, modify, write) is NOT atomic in Python threads
        counter += 1

# --- Setup ---
# Create two threads
thread1 = threading.Thread(target=increment_counter)
thread2 = threading.Thread(target=increment_counter)

print(f"Starting counter at: {counter}")
print(f"Each thread will perform {NUM_INCREMENTS} increments.")

# Start the threads
thread1.start()
thread2.start()

# Wait for both threads to finish execution
thread1.join()
thread2.join()

# --- Results ---
expected_result = 2 * NUM_INCREMENTS
print("\n--- Results ---")
print(f"Expected final counter value: {expected_result}")
print(f"Actual final counter value:   {counter}")

if counter != expected_result:
    print("\n!!! RACE CONDITION DETECTED !!!")
    print("The actual value is less than the expected value because updates were lost.")
else:
    # Note: On very simple, low-load systems, the race condition might not manifest,
    # but the underlying vulnerability is still present.
    print("\n(The race condition did not manifest this time, but the code is still unsafe.)")
```

### Explanation of the Example

1. **The Goal:** We want the final `counter` to be exactly $2 \times 100,000 = 200,000$.
2. **The Problematic Line:** `counter += 1` is the culprit.
3. **How the Race Happens (Hypothetical Scenario):**
    * **Initial State:** `counter` is 100.
    * **Thread 1 executes:** Reads `counter` (gets 100).
    * **Context Switch:** The OS pauses Thread 1 and switches to Thread 2.
    * **Thread 2 executes:** Reads `counter` (gets 100).
    * **Thread 2 modifies:** Calculates $100 + 1 = 101$.
    * **Thread 2 writes:** Sets `counter` to 101.
    * **Context Switch:** The OS switches back to Thread 1.
    * **Thread 1 modifies:** (It still thinks the value is 100, based on its initial read). Calculates $100 + 1 = 101$.
    * **Thread 1 writes:** Sets `counter` to 101.

**The Loss:** Two separate increment operations occurred, but the counter only increased by one (from 1
