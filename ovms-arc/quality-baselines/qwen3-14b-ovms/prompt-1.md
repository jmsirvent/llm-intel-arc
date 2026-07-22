Sure! Here's a Python function that returns the **nth Fibonacci number** using **memoization** to improve performance:

```python
def fibonacci(n, memo={}):
    """
    Returns the nth Fibonacci number using memoization.

    Parameters:
    n (int): The position in the Fibonacci sequence (0-based index).
    memo (dict): A dictionary to store already computed values (used for memoization).

    Returns:
    int: The nth Fibonacci number.
    """
    if n in memo:
        return memo[n]
    
    if n <= 1:
        return n
    
    memo[n] = fibonacci(n - 1, memo) + fibonacci(n - 2, memo)
    return memo[n]
```

### Example Usage:

```python
print(fibonacci(10))  # Output: 55
```

### Notes:
- This uses **recursive** approach with **memoization** (a dictionary to store computed values).
- The Fibonacci sequence is defined as:
  - `F(0) = 0`
  - `F(1) = 1`
  - `F(n) = F(n-1) + F(n-2)` for `n > 1`

### Alternative (Iterative with Memoization):

If you prefer an **iterative** approach with memoization:

```python
def fibonacci_iterative(n):
    memo = {0: 0, 1: 1}
    for i in range(2, n + 1):
        memo[i] = memo[i - 1] + memo[i - 2]
    return memo[n]
```

Let me know if you'd like a version using `lru_cache` from `functools`!
