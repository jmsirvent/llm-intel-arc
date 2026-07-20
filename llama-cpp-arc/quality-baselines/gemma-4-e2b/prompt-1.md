Here is a Python function that returns the $n$-th Fibonacci number using **memoization**.

Memoization is a technique where the results of expensive function calls are cached (stored) so that the next time the function is called with the same input, the cached result is returned instead of recomputing it.

```python
def fibonacci_memo(n, memo={}):
    """
    Calculates the nth Fibonacci number using memoization.

    The Fibonacci sequence starts: F(0)=0, F(1)=1, F(2)=1, F(3)=2, ...

    Args:
        n (int): The index of the Fibonacci number to calculate (must be non-negative).
        memo (dict): A dictionary used to store already computed results.

    Returns:
        int: The nth Fibonacci number.

    Raises:
        ValueError: If n is a negative number.
    """
    if n < 0:
        raise ValueError("Input 'n' must be a non-negative integer.")

    # 1. Check the memoization cache (the core of memoization)
    if n in memo:
        return memo[n]

    # 2. Base cases
    if n == 0:
        result = 0
    elif n == 1:
        result = 1
    
    # 3. Recursive step: Calculate and store the result
    else:
        # F(n) = F(n-1) + F(n-2)
        result = fibonacci_memo(n - 1, memo) + fibonacci_memo(n - 2, memo)

    # Store the calculated result in the memo before returning
    memo[n] = result
    return result

# --- Examples ---

# Calculate the 0th Fibonacci number
print(f"Fib(0): {fibonacci_memo(0)}")  # Output: 0

# Calculate the 1st Fibonacci number
print(f"Fib(1): {fibonacci_memo(1)}")  # Output: 1

# Calculate the 7th Fibonacci number (F(7) = 13)
print(f"Fib(7): {fibonacci_memo(7)}")  # Output: 13

# Calculate a larger number to show efficiency
print(f"Fib(10): {fibonacci_memo(10)}") # Output: 55
print(f"Fib(30): {fibonacci_memo(30)}") # Output: 832040
```

### Explanation of the Memoization Approach

1. **`memo={}` (The Cache):** We use a dictionary (`memo`) to store the results. This dictionary is passed along in the recursive calls.
2. **Cache Check (`if n in memo:`):** Before performing any calculation, the function first checks if the result for the current `n` has already been computed and stored in `memo`. If it exists, we immediately return the stored value, avoiding redundant recursive calls.
3. **Base Cases:** The recursion stops when $n=0$ (returns 0) or $n=1$ (returns 1).
4. **Recursive Calculation:** If the result is not in the cache, we calculate it using the standard Fibonacci definition: $F(n) = F(n-1) + F(n-2)$. Crucially, we pass the *same* `memo` dictionary down to the recursive calls.
5. **Storing the Result (`memo[n] = result`):** After calculating the result, we store it in the `memo` dictionary *before* returning it. This ensures that any future call requesting `fibonacci_memo(n)` will hit step 2 and return the stored value instantly.

### Why Memoization is Important Here

Without memoization, the standard recursive Fibonacci function has an exponential time complexity, $O(2^n)$, because it recalculates the same smaller Fibonacci numbers many times. With memoization, we ensure that each Fibonacci number is calculated only **once**, reducing the time complexity to linear time, $O(n)$.
