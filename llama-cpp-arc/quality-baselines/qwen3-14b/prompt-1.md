Sure! Here's a Python function that returns the **nth Fibonacci number** using **memoization** to improve performance:

```python
def fibonacci(n, memo={}):
    """
    Returns the nth Fibonacci number using memoization.

    Parameters:
    n (int): The index of the Fibonacci number to return (0-based index).
    memo (dict): A dictionary to store already computed Fibonacci numbers.

    Returns:
    int: The nth Fibonacci number.
    """
    if n in memo:
        return memo[n]
    
    if n == 0:
        return 0
    elif n == 1:
        return 1
    
    memo[n] = fibonacci(n - 1, memo) + fibonacci(n - 2, memo)
    return memo[n]
```

### Example Usage:

```python
print(fibonacci(10))  # Output: 55
print(fibonacci(0))   # Output: 0
print(fibonacci(1))   # Output: 1
```

### Notes:
- This implementation uses **memoization** via a dictionary to store previously computed values, which avoids redundant calculations and significantly improves performance for large `n`.
- The Fibonacci sequence is defined as:
  - `F(0) = 0`
  - `F(1) = 1`
  - `F(n) = F(n-1) + F(n-2)` for `n > 1`

### Alternative (with `lru_cache`):

If you're using Python 3.2 or newer, you can also use `functools.lru_cache` for memoization:

```python
from functools import lru_cache

@lru_cache(maxsize=None)
def fibonacci(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    return fibonacci(n - 1) + fibonacci(n - 2)
```

This version is cleaner and avoids manually managing the memo dictionary.
