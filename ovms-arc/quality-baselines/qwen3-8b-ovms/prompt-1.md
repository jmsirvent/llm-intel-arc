Certainly! Here's a Python function that returns the nth Fibonacci number using **memoization** to improve performance, especially for large values of `n`.

### ✅ Fibonacci with Memoization

```python
from functools import lru_cache

@lru_cache(maxsize=None)
def fibonacci(n):
    """
    Returns the nth Fibonacci number using memoization.
    
    Parameters:
    n (int): The position in the Fibonacci sequence (must be >= 0).
    
    Returns:
    int: The nth Fibonacci number.
    """
    if n < 0:
        raise ValueError("n must be a non-negative integer.")
    elif n == 0 or n == 1:
        return 1
    else:
        return fibonacci(n - 1) + fibonacci(n - 2)
```

### 🔍 Example Usage:

```python
print(fibonacci(0))  # Output: 1
print(fibonacci(1))  # Output: 1
print(fibonacci(5))  # Output: 8
print(fibonacci(10)) # Output: 89
```

### 📌 Notes:
- The `@lru_cache` decorator caches the results of the function calls, so repeated calls with the same `n` are very fast.
- This implementation uses **1-based indexing** for the Fibonacci sequence (i.e., `fibonacci(0) = 1`, `fibonacci(1) = 1`, `fibonacci(2) = 2`, etc.).
- If you want 0-based indexing (i.e., `fibonacci(0) = 0`, `fibonacci(1) = 1`), let me know and I can adjust it.

Let me know if you'd like a version that uses a different memoization technique (like a dictionary or a list).
