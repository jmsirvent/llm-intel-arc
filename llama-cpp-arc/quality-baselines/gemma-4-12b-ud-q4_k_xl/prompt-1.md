To implement a Fibonacci function with memoization in Python, the most efficient and "Pythonic" way is to use the built-in `functools.lru_cache` decorator. However, I will also show you how to implement it manually using a dictionary to help you understand the underlying logic.

### Option 1: The Pythonic Way (Using `lru_cache`)
This is the recommended approach for production code. It automatically handles the storage and lookup of previously calculated values.

```python
from functools import lru_cache

@lru_cache(maxsize=None)
def fib_memoized(n: int) -> int:
    if n <= 1:
        return n
    return fib_memoized(n - 1) + fib_memoized(n - 2)

# Example usage:
print(fib_memoized(50))  # Returns 12586269025 almost instantly
```

---

### Option 2: Manual Memoization (Using a Dictionary)
If you want to understand how memoization works under the hood, you can use a dictionary to store results.

```python
def fib_manual_memo(n: int, memo: dict = None) -> int:
    # Initialize the dictionary on the first call
    if memo is None:
        memo = {}
    
    # Check if the value is already in our "memory"
    if n in memo:
        return memo[n]
    
    # Base cases
    if n <= 1:
        return n
    
    # Recursive step: calculate, store in memo, and return
    memo[n] = fib_manual_memo(n - 1, memo) + fib_manual_memo(n - 2, memo)
    return memo[n]

# Example usage:
print(fib_manual_memo(50))
```

### Key Explanations:

1.  **The Problem with Standard Recursion:** A standard recursive Fibonacci function has a time complexity of $O(2^n)$ because it recalculates the same numbers thousands of times (e.g., to find `fib(5)`, it calculates `fib(3)` multiple times).
2.  **How Memoization Fixes This:** By storing the result of `fib(n)` the first time it is calculated, every subsequent call for that same `n` becomes a constant time $O(1)$ lookup.
3.  **Complexity:**
    *   **Time Complexity:** $O(n)$ — Each number from $0$ to $n$ is calculated exactly once.
    *   **Space Complexity:** $O(n)$ — To store the results in the dictionary/cache and to account for the recursion stack.

### Note on Recursion Limits
Python has a default recursion limit (usually 1000). If you try to find `fib(2000)` using the methods above, you will get a `RecursionError`. For extremely large numbers, an **iterative approach** is better:

```python
def fib_iterative(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```
